//
//  ChatSessionSegmenter.swift
//  claude-cursor
//
//  Splits one on-disk session log into N sidebar entries — one per
//  `(bundleIdentifier, browserToolName)` group — and writes the results
//  to the `chat_session_segments` / `chat_session_segment_turns` tables.
//  Runs at end-of-session (explicit "New Chat" button or auto-end) and
//  from the backfill runner on first launch.
//
//  Two design choices worth calling out:
//
//  1) We re-parse the session_*.md file from disk rather than reading
//     `ObserverAgent.recentlyObservedTurns`. That in-memory ring buffer
//     is capped at 50 turns (`ObserverAgent.maxInMemoryTurnsRetained`),
//     so long sessions would be silently truncated. The parser path
//     also gives the backfill runner a single code path.
//
//  2) Row inserts happen with a HEURISTIC title ("first user utterance
//     trimmed to 60 chars") so the sidebar shows something immediately.
//     A separate async `renameSegmentsWithBatchedClaudeCall` step calls
//     Claude ONCE per session asking for K titles in a single JSON
//     response and UPDATEs the rows in place. One call is ~K× cheaper
//     than K individual calls and caps end-of-session LLM load.
//

import Foundation

/// Snapshot of the session-end event taken on the main actor *before*
/// the async compress/segment work begins. The owning `CompanionManager`
/// nils `currentSessionObserverAgent` synchronously in
/// `endCurrentSessionAndCompressForObserver`, so without snapshotting
/// the pointers first, a fast second "New Chat" click could lose the
/// log URL / session identifier.
struct ChatSessionEndSnapshot {
    let sessionIdentifier: String
    let sessionLogFileURL: URL
    let sessionEndedAt: Date
}

/// Post-notification name fired after a session's segments land in
/// SQLite. The chat sidebar model subscribes to trigger a refresh.
extension Notification.Name {
    static let chatSessionSegmentsDidChange = Notification.Name("ChatSessionSegmentsDidChange")
}

/// Pure result of the splitting algorithm. Split out from the SQLite
/// write path so `ChatSessionSegmenterTests` can exercise just the
/// boundary / sandwich-merge rules without needing a DB.
struct ProposedChatSessionSegment {
    let appName: String
    let bundleIdentifier: String
    let browserHostname: String?
    let browserToolName: String?
    /// Parsed turns belonging to this segment, in original session order.
    let turnsInOrder: [ParsedSessionTurn]
}

@MainActor
final class ChatSessionSegmenter {

    // MARK: - Dependencies

    private let patternDatabase: PatternDatabase
    private let claudeAPI: ClaudeAPI

    /// The sandwich-merge rule absorbs a singleton group into a neighbor
    /// only when the time gap between the flanking groups is under this
    /// many seconds. 180s (3 minutes) is the plan-approved default.
    /// Exposed as a stored property so unit tests can override.
    let sandwichMergeMaxGapSeconds: TimeInterval

    /// Heuristic title length cap. Long enough to be a useful label,
    /// short enough to avoid horizontal truncation in the 220pt sidebar.
    private let heuristicTitleMaxCharacters: Int = 60

    // MARK: - Init

    init(
        patternDatabase: PatternDatabase,
        claudeAPI: ClaudeAPI,
        sandwichMergeMaxGapSeconds: TimeInterval = 180
    ) {
        self.patternDatabase = patternDatabase
        self.claudeAPI = claudeAPI
        self.sandwichMergeMaxGapSeconds = sandwichMergeMaxGapSeconds
    }

    // MARK: - Public Entry Point

    /// Main segmenter driver. Parses the session log, splits into segments,
    /// inserts rows with heuristic titles, and then kicks off a single
    /// batched Claude call to upgrade the titles. On Claude failure the
    /// heuristic titles remain — the sidebar never shows empty rows.
    func segmentAndInsert(forSessionEndSnapshot snapshot: ChatSessionEndSnapshot) async {
        guard let parsedSessionLog = ChatSessionLogParser.parseSessionLog(at: snapshot.sessionLogFileURL) else {
            print("⚠️ ChatSessionSegmenter: could not parse \(snapshot.sessionLogFileURL.lastPathComponent)")
            return
        }
        guard !parsedSessionLog.turnsInOrder.isEmpty else {
            // Zero-turn sessions: the observer created the file but the user
            // never actually engaged. Nothing worth surfacing in the sidebar.
            return
        }

        let proposedSegments = Self.splitTurnsIntoSegments(
            parsedTurns: parsedSessionLog.turnsInOrder,
            sandwichMergeMaxGapSeconds: sandwichMergeMaxGapSeconds
        )

        // Insert every segment + its turns synchronously so the sidebar
        // can refresh immediately with heuristic titles.
        var insertedSegmentIDsForRename: [(segmentID: String, segment: ProposedChatSessionSegment)] = []
        let transcriptFilePath = snapshot.sessionLogFileURL.path
        let sessionEndedAtISO = Self.iso8601String(fromDate: snapshot.sessionEndedAt)

        for proposedSegment in proposedSegments {
            guard let firstTurn = proposedSegment.turnsInOrder.first,
                  let lastTurn = proposedSegment.turnsInOrder.last else {
                continue
            }

            let heuristicTitle = heuristicTaskName(
                fromFirstUserUtterance: firstTurn.userUtterance
            )

            let segmentID = UUID().uuidString.lowercased()

            patternDatabase.insertChatSessionSegment(
                segmentID: segmentID,
                parentSessionID: parsedSessionLog.sessionIdentifier,
                appName: proposedSegment.appName,
                bundleIdentifier: proposedSegment.bundleIdentifier,
                browserHostname: proposedSegment.browserHostname,
                browserToolName: proposedSegment.browserToolName,
                taskName: heuristicTitle,
                taskNameSource: "heuristic",
                startedAt: firstTurn.timestampISO8601,
                endedAt: lastTurn.timestampISO8601.isEmpty
                    ? sessionEndedAtISO
                    : lastTurn.timestampISO8601,
                turnCount: proposedSegment.turnsInOrder.count,
                transcriptPath: transcriptFilePath,
                turnRangeStart: firstTurn.turnIndexInSessionFile,
                turnRangeEnd: lastTurn.turnIndexInSessionFile
            )

            let denormalizedTurns: [SegmentTurnInput] = proposedSegment.turnsInOrder
                .enumerated()
                .map { positionInSegment, parsedTurn in
                    SegmentTurnInput(
                        turnIndex: positionInSegment,
                        timestamp: parsedTurn.timestampISO8601,
                        userText: parsedTurn.userUtterance,
                        assistantText: parsedTurn.assistantResponse
                    )
                }
            patternDatabase.insertSegmentTurns(
                segmentID: segmentID,
                turns: denormalizedTurns
            )

            insertedSegmentIDsForRename.append((segmentID, proposedSegment))
        }

        NotificationCenter.default.post(name: .chatSessionSegmentsDidChange, object: nil)

        // Upgrade titles in the background. A failure keeps the heuristic
        // title so the sidebar is never blank.
        if !insertedSegmentIDsForRename.isEmpty {
            await renameSegmentsWithBatchedClaudeCall(
                segmentsToRename: insertedSegmentIDsForRename
            )
        }
    }

    // MARK: - Pure Splitting Algorithm

    /// Walks `parsedTurns` once, splitting whenever
    /// `(bundleIdentifier, browserToolName)` changes between consecutive
    /// turns. Then applies the sandwich-merge rule to absorb short
    /// context-switch interludes (e.g. flipping to Slack for one message
    /// mid-VS-Code-session) back into the surrounding group.
    ///
    /// Pure / static so unit tests can exercise boundary cases without
    /// constructing a segmenter instance (no DB, no Claude).
    static func splitTurnsIntoSegments(
        parsedTurns: [ParsedSessionTurn],
        sandwichMergeMaxGapSeconds: TimeInterval
    ) -> [ProposedChatSessionSegment] {

        let coarselyGroupedSegments = coarselyGroupTurnsByConsecutiveAppContext(
            parsedTurns: parsedTurns
        )

        return applySandwichMergeRule(
            coarselyGroupedSegments: coarselyGroupedSegments,
            sandwichMergeMaxGapSeconds: sandwichMergeMaxGapSeconds
        )
    }

    /// First pass: walk turns in order and start a new segment every time
    /// the `(bundleIdentifier, browserToolName)` pair changes. Identity
    /// is based on these two fields — NOT `appName` — because two different
    /// Chrome tabs (Linear vs Figma) share the same bundleID but should
    /// split into two sidebar folders.
    private static func coarselyGroupTurnsByConsecutiveAppContext(
        parsedTurns: [ParsedSessionTurn]
    ) -> [ProposedChatSessionSegment] {
        var groupedSegments: [ProposedChatSessionSegment] = []
        var currentGroupedTurns: [ParsedSessionTurn] = []
        var currentBundleIdentifier: String?
        var currentBrowserToolName: String?
        var currentAppName: String = ""
        var currentBrowserHostname: String?

        func flushCurrentGroup() {
            guard !currentGroupedTurns.isEmpty else { return }
            groupedSegments.append(ProposedChatSessionSegment(
                appName: currentAppName,
                bundleIdentifier: currentBundleIdentifier ?? "",
                browserHostname: currentBrowserHostname,
                browserToolName: currentBrowserToolName,
                turnsInOrder: currentGroupedTurns
            ))
            currentGroupedTurns = []
        }

        for parsedTurn in parsedTurns {
            let isFirstTurnInWalk = currentBundleIdentifier == nil && currentGroupedTurns.isEmpty

            // Identity changes when EITHER key field differs from the
            // in-flight group. `bundleIdentifier` handles app switches;
            // `browserToolName` handles cross-tool browser hops.
            let identityDiverged = !isFirstTurnInWalk && (
                parsedTurn.frontmostBundleIdentifier != (currentBundleIdentifier ?? "") ||
                parsedTurn.browserToolName != currentBrowserToolName
            )

            if identityDiverged {
                flushCurrentGroup()
            }

            if currentGroupedTurns.isEmpty {
                currentBundleIdentifier = parsedTurn.frontmostBundleIdentifier
                currentBrowserToolName = parsedTurn.browserToolName
                currentAppName = parsedTurn.frontmostAppName
                currentBrowserHostname = parsedTurn.browserHostname
            }

            currentGroupedTurns.append(parsedTurn)
        }

        flushCurrentGroup()
        return groupedSegments
    }

    /// Second pass: absorbs singleton groups into whichever neighbor they
    /// better belong to when the outer pattern is "A → B (1 turn) → A"
    /// with a small time gap. Prevents a quick Slack interlude from
    /// fragmenting a long VS Code session into three sidebar entries.
    ///
    /// Start-edge and end-edge singletons always stay (only one neighbor
    /// exists, so the pattern doesn't apply).
    private static func applySandwichMergeRule(
        coarselyGroupedSegments: [ProposedChatSessionSegment],
        sandwichMergeMaxGapSeconds: TimeInterval
    ) -> [ProposedChatSessionSegment] {
        guard coarselyGroupedSegments.count >= 3 else {
            return coarselyGroupedSegments
        }

        var mergedSegments: [ProposedChatSessionSegment] = []
        var indexOfSegmentBeingConsidered = 0

        while indexOfSegmentBeingConsidered < coarselyGroupedSegments.count {
            let currentSegment = coarselyGroupedSegments[indexOfSegmentBeingConsidered]

            // Can't sandwich the first segment (no left neighbor).
            let hasLeftNeighbor = !mergedSegments.isEmpty
            let hasRightNeighbor = (indexOfSegmentBeingConsidered + 1) < coarselyGroupedSegments.count

            let isSingletonCandidate = currentSegment.turnsInOrder.count == 1
                && hasLeftNeighbor
                && hasRightNeighbor

            if isSingletonCandidate {
                let leftNeighbor = mergedSegments[mergedSegments.count - 1]
                let rightNeighbor = coarselyGroupedSegments[indexOfSegmentBeingConsidered + 1]

                let neighborsShareIdentity =
                    leftNeighbor.bundleIdentifier == rightNeighbor.bundleIdentifier &&
                    leftNeighbor.browserToolName == rightNeighbor.browserToolName

                let timeGapBetweenNeighbors = Self.secondsBetween(
                    endOf: leftNeighbor,
                    startOf: rightNeighbor
                )

                let shouldMerge = neighborsShareIdentity
                    && timeGapBetweenNeighbors != nil
                    && timeGapBetweenNeighbors! < sandwichMergeMaxGapSeconds

                if shouldMerge {
                    let singletonTurn = currentSegment.turnsInOrder[0]
                    let timeToLeft = abs(Self.secondsBetween(
                        endOf: leftNeighbor,
                        startOfTurn: singletonTurn
                    ) ?? .infinity)
                    let timeToRight = abs(Self.secondsBetween(
                        startOf: rightNeighbor,
                        endOfTurn: singletonTurn
                    ) ?? .infinity)

                    if timeToLeft <= timeToRight {
                        // Absorb into the left neighbor (already in
                        // mergedSegments); keep right as its own.
                        let absorbedIntoLeft = ProposedChatSessionSegment(
                            appName: leftNeighbor.appName,
                            bundleIdentifier: leftNeighbor.bundleIdentifier,
                            browserHostname: leftNeighbor.browserHostname,
                            browserToolName: leftNeighbor.browserToolName,
                            turnsInOrder: leftNeighbor.turnsInOrder + [singletonTurn]
                        )
                        mergedSegments[mergedSegments.count - 1] = absorbedIntoLeft
                        indexOfSegmentBeingConsidered += 1  // skip the singleton; right gets processed next
                        continue
                    } else {
                        // Absorb into the right neighbor: prepend the
                        // singleton to right's turns and continue.
                        let absorbedIntoRight = ProposedChatSessionSegment(
                            appName: rightNeighbor.appName,
                            bundleIdentifier: rightNeighbor.bundleIdentifier,
                            browserHostname: rightNeighbor.browserHostname,
                            browserToolName: rightNeighbor.browserToolName,
                            turnsInOrder: [singletonTurn] + rightNeighbor.turnsInOrder
                        )
                        mergedSegments.append(absorbedIntoRight)
                        indexOfSegmentBeingConsidered += 2  // skip singleton AND right (we just consumed it)
                        continue
                    }
                }
            }

            mergedSegments.append(currentSegment)
            indexOfSegmentBeingConsidered += 1
        }

        return mergedSegments
    }

    // MARK: - Heuristic Title

    /// Generates the stopgap segment title from the first user utterance.
    /// The plan keeps this deliberately dumb — it's an immediate placeholder
    /// that the batched Claude rename upgrades seconds later.
    private func heuristicTaskName(fromFirstUserUtterance utterance: String) -> String {
        let trimmed = utterance.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "Untitled" }
        if trimmed.count <= heuristicTitleMaxCharacters { return trimmed }
        let prefix = trimmed.prefix(heuristicTitleMaxCharacters)
        return prefix + "…"
    }

    // MARK: - Batched Rename

    /// Sends the just-inserted segments to Claude in a SINGLE request and
    /// asks for K short titles as JSON. Each title becomes an UPDATE on the
    /// matching row with `task_name_source = 'llm'`. A failure keeps the
    /// heuristic titles so the sidebar is never empty.
    private func renameSegmentsWithBatchedClaudeCall(
        segmentsToRename: [(segmentID: String, segment: ProposedChatSessionSegment)]
    ) async {
        let promptForClaude = Self.buildBatchedRenamePrompt(segments: segmentsToRename)

        do {
            let (claudeResponseText, _) = try await claudeAPI.analyzeImage(
                images: [],
                systemPrompt: Self.batchedRenameSystemPrompt,
                userPrompt: promptForClaude,
                maxTokens: 1024
            )

            guard let titlesByIndex = Self.parseTitlesJSONResponse(claudeResponseText) else {
                print("⚠️ ChatSessionSegmenter: could not parse Claude rename response")
                return
            }

            // Apply each title back to its segment. The plan keeps
            // `heuristic` titles if the model returned a shorter array
            // than we asked for — safer than writing blanks.
            for (indexInBatch, segmentIdentifierTuple) in segmentsToRename.enumerated() {
                guard let newTitle = titlesByIndex[indexInBatch],
                      !newTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    continue
                }
                let clampedTitle = String(newTitle.prefix(heuristicTitleMaxCharacters))
                patternDatabase.updateSegmentTaskName(
                    segmentID: segmentIdentifierTuple.segmentID,
                    taskName: clampedTitle,
                    source: "llm"
                )
            }

            NotificationCenter.default.post(name: .chatSessionSegmentsDidChange, object: nil)
        } catch {
            print("⚠️ ChatSessionSegmenter: batched rename failed — keeping heuristic titles: \(error)")
        }
    }

    /// System prompt that constrains Claude to a strict JSON shape so
    /// `parseTitlesJSONResponse` doesn't need a schema-tolerant parser.
    private static let batchedRenameSystemPrompt: String = """
    You name chat session segments for a sidebar UI. Output ONLY strict JSON
    in this exact shape: {"titles":[{"index":0,"title":"..."},{"index":1,"title":"..."}]}.
    Each title MUST be ≤ 60 characters and describe the user's task — not the
    tool. Prefer specific phrasing ("fix auth refresh bug") over generic
    ("debugging"). Do not include any text outside the JSON object.
    """

    /// Builds the user prompt: one numbered block per segment containing
    /// the first + last ~3 turns. Using only the edges keeps the prompt
    /// small (~500-800 tokens per segment) while giving Claude enough
    /// signal to name the task.
    private static func buildBatchedRenamePrompt(
        segments: [(segmentID: String, segment: ProposedChatSessionSegment)]
    ) -> String {
        var promptLines: [String] = []
        promptLines.append("Name each of the following \(segments.count) segments. Return JSON per the system prompt.\n")

        for (indexInBatch, segmentTuple) in segments.enumerated() {
            let proposedSegment = segmentTuple.segment
            let appLabel = proposedSegment.browserToolName ?? proposedSegment.appName
            promptLines.append("--- Segment index: \(indexInBatch) (app: \(appLabel)) ---")

            let turns = proposedSegment.turnsInOrder
            let edgeSampledTurns: [ParsedSessionTurn]
            if turns.count <= 6 {
                edgeSampledTurns = turns
            } else {
                edgeSampledTurns = Array(turns.prefix(3)) + Array(turns.suffix(3))
            }

            for parsedTurn in edgeSampledTurns {
                promptLines.append("User: \(parsedTurn.userUtterance)")
                promptLines.append("Assistant: \(parsedTurn.assistantResponse)")
            }
        }

        return promptLines.joined(separator: "\n")
    }

    /// Extracts the `titles` array from Claude's JSON response. Returns
    /// a dictionary keyed by segment-batch-index for O(1) lookup in the
    /// UPDATE loop. Robust to Claude wrapping the JSON in ``` fences.
    private static func parseTitlesJSONResponse(_ responseText: String) -> [Int: String]? {
        let stripped = stripMarkdownCodeFence(fromText: responseText)
        guard let jsonData = stripped.data(using: .utf8) else { return nil }
        guard let parsed = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let titlesArray = parsed["titles"] as? [[String: Any]] else {
            return nil
        }

        var titlesByIndex: [Int: String] = [:]
        for titleEntry in titlesArray {
            guard let entryIndex = titleEntry["index"] as? Int,
                  let entryTitle = titleEntry["title"] as? String else {
                continue
            }
            titlesByIndex[entryIndex] = entryTitle
        }
        return titlesByIndex
    }

    private static func stripMarkdownCodeFence(fromText text: String) -> String {
        var working = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if working.hasPrefix("```") {
            // Drop everything up to the end of the first newline so
            // "```json\n{...}" still parses.
            if let firstNewlineIndex = working.firstIndex(of: "\n") {
                working = String(working[working.index(after: firstNewlineIndex)...])
            }
        }
        if working.hasSuffix("```") {
            working = String(working.dropLast(3))
        }
        return working.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Time Helpers

    /// Returns the signed seconds between the end of the left segment and
    /// the start of the right segment. Nil when either timestamp is
    /// missing from the parsed turns (legacy malformed logs).
    private static func secondsBetween(
        endOf leftSegment: ProposedChatSessionSegment,
        startOf rightSegment: ProposedChatSessionSegment
    ) -> TimeInterval? {
        guard let leftEnd = leftSegment.turnsInOrder.last?.timestampISO8601,
              let rightStart = rightSegment.turnsInOrder.first?.timestampISO8601,
              let leftDate = iso8601Date(fromString: leftEnd),
              let rightDate = iso8601Date(fromString: rightStart) else {
            return nil
        }
        return rightDate.timeIntervalSince(leftDate)
    }

    /// Distance from a segment's last turn to an external turn. Used to
    /// pick which neighbor absorbs a singleton during sandwich-merge.
    private static func secondsBetween(
        endOf leftSegment: ProposedChatSessionSegment,
        startOfTurn turn: ParsedSessionTurn
    ) -> TimeInterval? {
        guard let leftEnd = leftSegment.turnsInOrder.last?.timestampISO8601,
              let leftDate = iso8601Date(fromString: leftEnd),
              let turnDate = iso8601Date(fromString: turn.timestampISO8601) else {
            return nil
        }
        return turnDate.timeIntervalSince(leftDate)
    }

    /// Distance from a segment's first turn to an external turn.
    private static func secondsBetween(
        startOf rightSegment: ProposedChatSessionSegment,
        endOfTurn turn: ParsedSessionTurn
    ) -> TimeInterval? {
        guard let rightStart = rightSegment.turnsInOrder.first?.timestampISO8601,
              let rightDate = iso8601Date(fromString: rightStart),
              let turnDate = iso8601Date(fromString: turn.timestampISO8601) else {
            return nil
        }
        return rightDate.timeIntervalSince(turnDate)
    }

    private static func iso8601Date(fromString iso: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: iso)
    }

    private static func iso8601String(fromDate date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}
