//
//  ChatSessionBackfillRunner.swift
//  claude-cursor
//
//  One-shot pass that retro-files the existing `raw/sessions/session_*.md`
//  logs into the new `chat_session_segments` table on first launch after
//  ship. Delegates to `ChatSessionSegmenter` for the actual splitting, so
//  the live and backfill paths share code.
//
//  Gated two ways:
//    1. A UserDefaults version key — once the first-launch run succeeds,
//       `runIfNeededForFirstLaunchBackfill()` returns early on subsequent
//       launches.
//    2. A per-session idempotency check against
//       `PatternDatabase.distinctParentSessionIDs()` — prevents duplicate
//       rows on files that already made it through, which keeps the
//       runner correct even if the version bump didn't land (e.g. app
//       was force-quit mid-backfill).
//
//  Throttled to ONE segmenter call at a time. The segmenter makes a
//  batched Claude call per session to upgrade titles, and fanning those
//  out in parallel could spike LLM spend during a single launch.
//

import Foundation

@MainActor
final class ChatSessionBackfillRunner {

    // MARK: - Dependencies

    private let wikiManager: WikiManager
    private let patternDatabase: PatternDatabase
    private let chatSessionSegmenter: ChatSessionSegmenter

    /// UserDefaults key that gates the one-time first-launch backfill.
    /// Bumped to `currentBackfillVersion` on successful completion;
    /// increment the expected value if the segmenter rules change enough
    /// to warrant re-processing every file.
    private let backfillVersionUserDefaultsKey: String = "ClaudeCursor.chatSegmentsBackfillVersion"
    private let currentBackfillVersion: Int = 1

    /// Cap for the first-run pass. Older session files beyond this count
    /// surface in the sidebar under an "Older sessions — N not yet indexed"
    /// row; clicking that row calls
    /// `backfillAdditionalUnprocessedSessions(maximumAdditionalFilesToProcess:)`
    /// to process the next batch in the background.
    private let firstRunMaximumSessionsToBackfill: Int = 50

    // MARK: - Init

    init(
        wikiManager: WikiManager,
        patternDatabase: PatternDatabase,
        chatSessionSegmenter: ChatSessionSegmenter
    ) {
        self.wikiManager = wikiManager
        self.patternDatabase = patternDatabase
        self.chatSessionSegmenter = chatSessionSegmenter
    }

    // MARK: - Public API

    /// Runs the first-launch backfill if it hasn't completed yet. Safe to
    /// call multiple times — both the version guard and the per-session
    /// existence check prevent duplicate work. Intended to be invoked as
    /// `Task.detached(priority: .background)` from `CompanionManager.init`
    /// after `patternDatabase.open()`.
    func runIfNeededForFirstLaunchBackfill() async {
        let alreadyRunAtVersion = UserDefaults.standard.integer(
            forKey: backfillVersionUserDefaultsKey
        )
        guard alreadyRunAtVersion < currentBackfillVersion else { return }

        await backfillSessionLogs(
            maximumFilesToProcess: firstRunMaximumSessionsToBackfill
        )

        // Only bump the version after the run returns — a throw/crash
        // leaves the gate unchanged so the next launch picks up where we
        // left off.
        UserDefaults.standard.set(
            currentBackfillVersion,
            forKey: backfillVersionUserDefaultsKey
        )
    }

    /// Processes the next batch of un-backfilled session files. Triggered
    /// by the "Older sessions — N not yet indexed" sidebar row once the
    /// initial 50-file pass has completed. The sidebar refresh itself is
    /// driven by the segmenter's `.chatSessionSegmentsDidChange` posts;
    /// callers don't need to listen to this method's completion.
    func backfillAdditionalUnprocessedSessions(
        maximumAdditionalFilesToProcess: Int
    ) async {
        await backfillSessionLogs(
            maximumFilesToProcess: maximumAdditionalFilesToProcess
        )
    }

    /// Returns the number of `session_*.md` files on disk that haven't
    /// been segmented yet. The sidebar uses this to decide whether to show
    /// the "Older sessions — N not yet indexed" row. Filename-based (no
    /// file reads) so the check is cheap even with hundreds of logs.
    func countOfUnbackfilledSessionLogFilesOnDisk() -> Int {
        let allSessionLogURLs = Self.enumerateSessionLogFileURLsNewestFirst(
            inDirectory: wikiManager.rawSessionsDirectoryURL
        )
        let alreadyBackfilledParentSessionIDs = patternDatabase.distinctParentSessionIDs()

        var unbackfilledCount = 0
        for sessionLogURL in allSessionLogURLs {
            let filenameDerivedID = Self.extractSessionIdentifierFromFilename(
                fileURL: sessionLogURL
            )
            if let id = filenameDerivedID,
               alreadyBackfilledParentSessionIDs.contains(id) {
                continue
            }
            // Includes both: (a) files whose parsed sessionID isn't in
            // the DB yet, and (b) files whose filename we can't parse —
            // the second case is rare but we want the count to be a
            // conservative upper bound rather than silently drop them.
            unbackfilledCount += 1
        }
        return unbackfilledCount
    }

    // MARK: - Core Backfill Loop

    /// Shared worker for both the first-launch and "Older sessions" paths.
    /// Walks session log files newest-first, skips any whose parsed
    /// session identifier already has segment rows, and hands the rest
    /// to the segmenter ONE AT A TIME.
    ///
    /// The sequential throttle is deliberate: the segmenter's batched
    /// rename makes a Claude call per session, and running these in
    /// parallel would fan out an unpredictable amount of LLM spend during
    /// a single launch.
    private func backfillSessionLogs(
        maximumFilesToProcess: Int
    ) async {
        guard maximumFilesToProcess > 0 else { return }

        let sessionLogURLsNewestFirst = Self.enumerateSessionLogFileURLsNewestFirst(
            inDirectory: wikiManager.rawSessionsDirectoryURL
        )
        if sessionLogURLsNewestFirst.isEmpty { return }

        // Take the snapshot once at the start of the run. We don't refresh
        // this between iterations because the segmenter's own inserts feed
        // back into the same table and would make the set grow on every
        // loop anyway — effectively a no-op refresh for the runner.
        let alreadyBackfilledParentSessionIDs = patternDatabase.distinctParentSessionIDs()

        var filesProcessedThisRun = 0
        for sessionLogURL in sessionLogURLsNewestFirst {
            guard filesProcessedThisRun < maximumFilesToProcess else { break }

            // Cheap pre-filter on filename — lets us skip most already-
            // backfilled files without opening them.
            if let filenameDerivedID = Self.extractSessionIdentifierFromFilename(
                fileURL: sessionLogURL
            ), alreadyBackfilledParentSessionIDs.contains(filenameDerivedID) {
                continue
            }

            // Parse the file to get the authoritative session identifier
            // from frontmatter. Filename-derived IDs should match, but we
            // trust the frontmatter as the canonical source.
            guard let parsedSessionLog = ChatSessionLogParser.parseSessionLog(
                at: sessionLogURL
            ) else {
                // Unparseable file — skip and move on. A malformed log
                // should never break the backfill loop for the rest.
                continue
            }

            // Second idempotency check now that we have the authoritative
            // ID. Handles the rare case where the filename parser
            // disagrees with the frontmatter.
            if !parsedSessionLog.sessionIdentifier.isEmpty,
               alreadyBackfilledParentSessionIDs.contains(parsedSessionLog.sessionIdentifier) {
                continue
            }

            // Session end time is unknown for historical files — use the
            // ISO string in frontmatter if present, otherwise fall back to
            // the file's content-modification date.
            let fileModificationDateFallback = (try? sessionLogURL.resourceValues(
                forKeys: [.contentModificationDateKey]
            ))?.contentModificationDate ?? Date()

            let resolvedSessionEndedAt: Date = {
                if let endedAtISO = parsedSessionLog.sessionEndedAtISO8601,
                   let parsedDate = Self.iso8601Date(fromString: endedAtISO) {
                    return parsedDate
                }
                return fileModificationDateFallback
            }()

            let snapshot = ChatSessionEndSnapshot(
                sessionIdentifier: parsedSessionLog.sessionIdentifier.isEmpty
                    ? UUID().uuidString.lowercased()
                    : parsedSessionLog.sessionIdentifier,
                sessionLogFileURL: sessionLogURL,
                sessionEndedAt: resolvedSessionEndedAt
            )

            await chatSessionSegmenter.segmentAndInsert(
                forSessionEndSnapshot: snapshot
            )

            filesProcessedThisRun += 1
        }
    }

    // MARK: - Filesystem Helpers

    /// Returns `session_*.md` file URLs in the given directory sorted by
    /// content-modification date DESCENDING (newest first). Entries that
    /// aren't regular session log files (wrong prefix / extension) are
    /// filtered out.
    private static func enumerateSessionLogFileURLsNewestFirst(
        inDirectory directoryURL: URL
    ) -> [URL] {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: directoryURL.path) else { return [] }

        guard let directoryContents = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        let sessionLogURLs = directoryContents.filter { candidateURL in
            let filename = candidateURL.lastPathComponent
            return filename.hasPrefix("session_") && filename.hasSuffix(".md")
        }

        return sessionLogURLs.sorted { leftURL, rightURL in
            let leftDate = (try? leftURL.resourceValues(
                forKeys: [.contentModificationDateKey]
            ))?.contentModificationDate ?? .distantPast
            let rightDate = (try? rightURL.resourceValues(
                forKeys: [.contentModificationDateKey]
            ))?.contentModificationDate ?? .distantPast
            return leftDate > rightDate
        }
    }

    /// Pulls the session identifier out of a filename shaped like
    /// `session_<yyyyMMdd>_<HHmmss>_<sessionIdentifier>.md`. The identifier
    /// may contain underscores (UUIDs don't, but we don't assume), so
    /// everything after the time component is joined back together.
    /// Returns nil for filenames that don't match the expected layout.
    private static func extractSessionIdentifierFromFilename(fileURL: URL) -> String? {
        let filenameWithoutExtension = fileURL.deletingPathExtension().lastPathComponent
        let components = filenameWithoutExtension.split(
            separator: "_",
            omittingEmptySubsequences: false
        )
        // Expected: ["session", "<yyyyMMdd>", "<HHmmss>", "<sessionID...>"]
        guard components.count >= 4, components[0] == "session" else { return nil }
        return components[3...].joined(separator: "_")
    }

    private static func iso8601Date(fromString iso: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: iso)
    }
}
