//
//  ObserverAgent.swift
//  claude-cursor
//
//  Logs every user ↔ Claude interaction to an append-only session markdown
//  file at `raw/sessions/session_<yyyyMMdd_HHmmss>_<uuid>.md` (UTC date prefix
//  plus unique id for sorting and collision safety). When the session ends (the
//  user is idle beyond a threshold, or the app quits), hands the session log
//  to `SessionCompressor` for LLM-driven summarization and triggers a
//  lightweight wiki ingest so the observations become available to future
//  queries.
//
//  The observer writes a "raw" log (every turn, unabridged) and the
//  compressor produces a "cooked" summary (bullet points, key intents,
//  noteworthy outcomes). Only the cooked output flows into the wiki as a
//  source-summary page — raw logs stay on disk for provenance.
//

import Foundation

// MARK: - Session Log Schema

/// One logged turn in a session: user utterance → assistant response, plus
/// context about the app in focus and whether the turn triggered pointing,
/// lesson, or answer output.
struct ObservedSessionTurn {
    let timestampISO8601: String
    let userUtterance: String
    let assistantResponse: String
    let frontmostAppName: String

    /// Bundle identifier of the frontmost app at the time of the turn. Used
    /// by the chat session segmenter to group consecutive turns into per-app
    /// sidebar entries. Empty string when the frontmost app can't be
    /// resolved (e.g. Finder transitions); legacy session files parsed back
    /// also surface as empty.
    let frontmostBundleIdentifier: String

    /// Hostname of the active tab when the frontmost app is an allowlisted
    /// Chromium-family browser. Nil for native apps and for browser turns
    /// where the URL extraction timed out or was denied. Full URL is NEVER
    /// persisted — only the hostname — so tokens / search queries in URL
    /// query strings don't land on disk.
    let browserHostname: String?

    /// Human-friendly tool name derived from `browserHostname` (e.g.
    /// "Linear", "Figma"). Feeds the sidebar sub-folder label.
    let browserToolName: String?

    let outputModeUsed: String  // "navigation" | "answer" | "lesson" | "chat" | ""
}

/// Metadata about a session collected by the observer. Written to the top
/// of the session file as frontmatter so compressor and future queries can
/// reason about when/where the session happened.
struct ObservedSessionMetadata {
    let sessionIdentifier: String
    let startedAtISO8601: String
    var endedAtISO8601: String?
    var frontmostAppsSeen: [String]
    var turnCount: Int
}

// MARK: - Observer Agent

/// Session-scoped observer. One instance is created per session; the manager
/// starts a new session on first interaction and ends it on idle timeout or
/// app quit. The agent owns its on-disk log file and flushes each turn
/// immediately so a crash loses at most the in-memory counters.
@MainActor
final class ObserverAgent {

    private let wikiManager: WikiManager
    private let sessionCompressor: SessionCompressor

    private(set) var sessionMetadata: ObservedSessionMetadata
    /// Last path component of `sessionLogFileURL` — single source of truth for
    /// UserDefaults cold-start recap and any code that must reopen this file.
    private(set) var sessionLogFilename: String
    /// Absolute URL of this session's raw markdown log. Exposed so the chat
    /// session segmenter and backfill runner can re-parse the file on end —
    /// the observer's in-memory ring buffer is capped at 50 turns and would
    /// lose data for long sessions.
    let sessionLogFileURL: URL

    /// In-memory ring buffer of recent turns — used by SessionCompressor on
    /// session end. The on-disk log has the full history; this buffer avoids
    /// re-reading the file at compression time when the session is short.
    private(set) var recentlyObservedTurns: [ObservedSessionTurn] = []

    /// Cap on the in-memory buffer. Long sessions still persist every turn
    /// to disk but only the most recent ones are compressor-hot.
    private let maxInMemoryTurnsRetained: Int = 50

    /// True once the session has been ended and compressed — prevents
    /// double-compression if app quit fires after idle-timeout end.
    private(set) var hasBeenEnded: Bool = false

    init(
        wikiManager: WikiManager,
        sessionCompressor: SessionCompressor,
        sessionIdentifier: String? = nil
    ) {
        let resolvedSessionIdentifier = sessionIdentifier ?? ObserverAgent.generateSessionIdentifier()
        self.wikiManager = wikiManager
        self.sessionCompressor = sessionCompressor

        let now = Date()
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let nowISOString = iso.string(from: now)

        self.sessionMetadata = ObservedSessionMetadata(
            sessionIdentifier: resolvedSessionIdentifier,
            startedAtISO8601: nowISOString,
            endedAtISO8601: nil,
            frontmostAppsSeen: [],
            turnCount: 0
        )

        let sessionDatePrefixUTC = Self.sessionLogDatePrefixUTC(from: now)
        let sessionFilename =
            "session_\(sessionDatePrefixUTC)_\(resolvedSessionIdentifier).md"
        self.sessionLogFilename = sessionFilename
        self.sessionLogFileURL = wikiManager.rawSessionsDirectoryURL
            .appendingPathComponent(sessionFilename)

        writeInitialSessionFile(
            at: sessionLogFileURL,
            startedAt: nowISOString,
            sessionIdentifier: resolvedSessionIdentifier
        )
    }

    // MARK: - Public API

    /// Records a user↔assistant turn. Appends to the on-disk log immediately
    /// and keeps a copy in memory for faster compressor access at session end.
    /// PII stripping is applied before either write path so neither the on-
    /// disk log nor the compressor sees raw credit card numbers, SSNs, etc.
    ///
    /// `frontmostBundleIdentifier`, `browserHostname`, and `browserToolName`
    /// are all separately persisted so the chat session segmenter can group
    /// sidebar entries by `(bundleIdentifier, browserToolName)` without
    /// having to re-derive identity from the display name.
    func observeTurn(
        userUtterance: String,
        assistantResponse: String,
        frontmostAppName: String,
        frontmostBundleIdentifier: String,
        browserHostname: String?,
        browserToolName: String?,
        outputModeUsed: String
    ) {
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime]
        let timestampString = isoFormatter.string(from: Date())

        let strippedUserUtterance = PIIStripper.strip(fromText: userUtterance)
        let strippedAssistantResponse = PIIStripper.strip(fromText: assistantResponse)

        let observedTurn = ObservedSessionTurn(
            timestampISO8601: timestampString,
            userUtterance: strippedUserUtterance,
            assistantResponse: strippedAssistantResponse,
            frontmostAppName: frontmostAppName,
            frontmostBundleIdentifier: frontmostBundleIdentifier,
            browserHostname: browserHostname,
            browserToolName: browserToolName,
            outputModeUsed: outputModeUsed
        )

        recentlyObservedTurns.append(observedTurn)
        if recentlyObservedTurns.count > maxInMemoryTurnsRetained {
            recentlyObservedTurns.removeFirst(recentlyObservedTurns.count - maxInMemoryTurnsRetained)
        }

        sessionMetadata.turnCount += 1
        if !frontmostAppName.isEmpty, !sessionMetadata.frontmostAppsSeen.contains(frontmostAppName) {
            sessionMetadata.frontmostAppsSeen.append(frontmostAppName)
        }

        appendTurnToSessionFile(turn: observedTurn)
    }

    /// Ends the session, updates the session file's frontmatter with end
    /// time and final turn count, and hands the session off to the
    /// compressor. The compressor runs asynchronously — callers that need
    /// the compressed result can await this function.
    func endSessionAndCompress() async {
        guard !hasBeenEnded else { return }
        hasBeenEnded = true

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime]
        let endedAtString = isoFormatter.string(from: Date())
        sessionMetadata.endedAtISO8601 = endedAtString

        updateSessionFileWithEndTime(endedAt: endedAtString)

        // Only compress sessions with enough signal — one-turn sessions
        // typically aren't worth summarizing, and compressing empty
        // sessions wastes a Claude call.
        guard sessionMetadata.turnCount >= 2 else {
            print("🔎 ObserverAgent: session too short to compress (\(sessionMetadata.turnCount) turns) — skipping")
            return
        }

        await sessionCompressor.compressSessionIntoWikiPage(
            sessionMetadata: sessionMetadata,
            observedTurns: recentlyObservedTurns,
            sessionLogFileURL: sessionLogFileURL
        )
    }

    // MARK: - Session File I/O

    private func writeInitialSessionFile(
        at fileURL: URL,
        startedAt startedAtISOString: String,
        sessionIdentifier: String
    ) {
        let initialContent = """
        ---
        type: session
        session_id: \(sessionIdentifier)
        started_at: \(startedAtISOString)
        ended_at:
        frontmost_apps: []
        turn_count: 0
        ---

        # Session \(sessionIdentifier)

        ## Turns

        """
        do {
            try initialContent.write(to: fileURL, atomically: true, encoding: .utf8)
        } catch {
            print("⚠️ ObserverAgent: failed to create session file — \(error)")
        }
    }

    private func appendTurnToSessionFile(turn: ObservedSessionTurn) {
        // New pipe-separated header carries 4 fields inside the bracket so
        // `ChatSessionLogParser` can reconstruct full per-turn app context.
        // "-" is written for missing browser fields so the parse regex
        // always sees exactly 4 pipe-separated values.
        let browserHostnameField = turn.browserHostname?.isEmpty == false
            ? turn.browserHostname!
            : "-"
        let browserToolField = turn.browserToolName?.isEmpty == false
            ? turn.browserToolName!
            : "-"
        let outputModeField = turn.outputModeUsed.isEmpty ? "n/a" : turn.outputModeUsed

        let turnBlock = """

        ### \(turn.timestampISO8601) [\(turn.frontmostAppName)|\(turn.frontmostBundleIdentifier)|\(browserHostnameField)|\(browserToolField)] (\(outputModeField))

        **User:** \(turn.userUtterance)

        **Assistant:** \(turn.assistantResponse)

        """

        guard let turnBlockData = turnBlock.data(using: .utf8) else { return }

        do {
            let fileHandle = try FileHandle(forWritingTo: sessionLogFileURL)
            defer { try? fileHandle.close() }
            try fileHandle.seekToEnd()
            try fileHandle.write(contentsOf: turnBlockData)
        } catch {
            // Fall back to full rewrite if append failed (e.g., file was
            // deleted out from under us). Rare but don't want to lose the
            // turn entirely.
            print("⚠️ ObserverAgent: append failed (\(error)) — falling back to full rewrite")
            if let existingContent = try? String(contentsOf: sessionLogFileURL, encoding: .utf8) {
                try? (existingContent + turnBlock).write(to: sessionLogFileURL, atomically: true, encoding: .utf8)
            }
        }
    }

    private func updateSessionFileWithEndTime(endedAt endedAtISOString: String) {
        guard var fileContent = try? String(contentsOf: sessionLogFileURL, encoding: .utf8) else {
            return
        }

        // Update the ended_at, frontmost_apps, and turn_count frontmatter
        // fields. The rest of the file (turn history) is untouched.
        let appsListYAML = "[\(sessionMetadata.frontmostAppsSeen.joined(separator: ", "))]"
        fileContent = fileContent.replacingOccurrences(
            of: "ended_at:\n",
            with: "ended_at: \(endedAtISOString)\n"
        )
        fileContent = fileContent.replacingOccurrences(
            of: "frontmost_apps: []\n",
            with: "frontmost_apps: \(appsListYAML)\n"
        )
        fileContent = fileContent.replacingOccurrences(
            of: "turn_count: 0\n",
            with: "turn_count: \(sessionMetadata.turnCount)\n"
        )

        try? fileContent.write(to: sessionLogFileURL, atomically: true, encoding: .utf8)
    }

    // MARK: - Identifier Generation

    /// Stable unique id for frontmatter, wiki pages, and the filename suffix.
    static func generateSessionIdentifier() -> String {
        UUID().uuidString.lowercased()
    }

    /// `yyyyMMdd_HHmmss` in UTC for lexicographic sort of log files by start time.
    private static func sessionLogDatePrefixUTC(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: date)
    }
}
