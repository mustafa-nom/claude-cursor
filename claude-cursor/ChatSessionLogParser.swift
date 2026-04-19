//
//  ChatSessionLogParser.swift
//  claude-cursor
//
//  Parses the raw session_<id>.md files written by `ObserverAgent` back
//  into structured `ParsedSessionTurn` values. Used by:
//    - `ChatSessionSegmenter` on session end — the observer's in-memory
//      ring buffer is capped at 50 turns, so we replay the full log from
//      disk to avoid truncating long sessions.
//    - `ChatSessionBackfillRunner` on first launch after ship — retro-files
//      existing session logs into the new SQLite tables.
//
//  The parser tolerates TWO on-disk formats:
//    1. Legacy header: `### <iso> [<appName>] (<outputMode>)`  ← no bundleID column
//    2. New header:    `### <iso> [<appName>|<bundleID>|<hostname or "-">|<tool or "-">] (<outputMode>)`
//
//  Legacy files are flagged with `bundleIdentifier == ""`, which the
//  segmenter treats as a single-group session under the app name with no
//  browser sub-folder.
//

import Foundation

/// One turn extracted from a session markdown file. Field names
/// intentionally mirror `ObservedSessionTurn` so downstream code doesn't
/// have to translate between the two types.
struct ParsedSessionTurn {
    let timestampISO8601: String
    let userUtterance: String
    let assistantResponse: String
    let frontmostAppName: String

    /// Empty string for legacy (pre-bundleID) session files. Callers that
    /// need app-identity for segment grouping should treat empty bundle IDs
    /// as "use `frontmostAppName` directly — no browser sub-folder".
    let frontmostBundleIdentifier: String

    /// Nil for native apps and for sessions recorded before the browser
    /// columns were added. Never carries a full URL — the header format
    /// persists only hostname + tool name.
    let browserHostname: String?
    let browserToolName: String?

    let outputModeUsed: String

    /// Zero-based index of this turn in the parsed file's turn list. Useful
    /// for `chat_session_segments.turn_range_start`/`turn_range_end`.
    let turnIndexInSessionFile: Int
}

/// Structured parse result. Separate from `ParsedSessionTurn` so the
/// caller can also use session-level metadata (e.g. session id) when
/// building segment rows without re-parsing the frontmatter.
struct ParsedSessionLog {
    let sessionIdentifier: String
    let sessionStartedAtISO8601: String
    let sessionEndedAtISO8601: String?
    let turnsInOrder: [ParsedSessionTurn]
}

enum ChatSessionLogParser {

    // MARK: - Public API

    /// Parses a raw session log from disk. Returns nil when the file is
    /// missing, not UTF-8, or doesn't contain a frontmatter block. Missing
    /// turns are tolerated — an empty `turnsInOrder` array is valid and
    /// indicates a session the user never actually engaged with.
    static func parseSessionLog(at sessionLogFileURL: URL) -> ParsedSessionLog? {
        guard let fileContents = try? String(contentsOf: sessionLogFileURL, encoding: .utf8) else {
            return nil
        }
        return parseSessionLog(fromFileContents: fileContents)
    }

    /// Parses a raw session log from an already-loaded string. Exposed for
    /// unit tests so fixtures can be held inline instead of on disk.
    static func parseSessionLog(fromFileContents fileContents: String) -> ParsedSessionLog? {
        let (frontmatterYAML, afterFrontmatter) = splitFrontmatter(from: fileContents)
        guard let frontmatterYAML else { return nil }

        let sessionIdentifier = valueOfFrontmatterKey("session_id", in: frontmatterYAML) ?? ""
        let sessionStartedAt = valueOfFrontmatterKey("started_at", in: frontmatterYAML) ?? ""
        let sessionEndedAtRaw = valueOfFrontmatterKey("ended_at", in: frontmatterYAML) ?? ""
        let sessionEndedAt: String? = sessionEndedAtRaw.isEmpty ? nil : sessionEndedAtRaw

        let parsedTurns = parseTurnBlocks(fromBody: afterFrontmatter)

        return ParsedSessionLog(
            sessionIdentifier: sessionIdentifier,
            sessionStartedAtISO8601: sessionStartedAt,
            sessionEndedAtISO8601: sessionEndedAt,
            turnsInOrder: parsedTurns
        )
    }

    // MARK: - Frontmatter

    /// Splits `---\n...---\n<body>` into (frontmatter, body). Returns
    /// (nil, whole-string) when no frontmatter fences are present.
    private static func splitFrontmatter(
        from fileContents: String
    ) -> (frontmatter: String?, body: String) {
        guard fileContents.hasPrefix("---") else {
            return (nil, fileContents)
        }

        // Skip the opening fence (either `---\n` or `---\r\n`).
        let afterOpeningFence = fileContents.dropFirst("---".count)
        guard let closingFenceRange = afterOpeningFence.range(of: "\n---") else {
            return (nil, fileContents)
        }

        let frontmatterBody = afterOpeningFence[..<closingFenceRange.lowerBound]
        let afterClosingFence = afterOpeningFence[closingFenceRange.upperBound...]

        // Drop the newline immediately after the closing `---` if present.
        let trimmedAfterClosingFence: Substring
        if let newlineIndex = afterClosingFence.firstIndex(of: "\n") {
            trimmedAfterClosingFence = afterClosingFence[afterClosingFence.index(after: newlineIndex)...]
        } else {
            trimmedAfterClosingFence = afterClosingFence
        }

        return (String(frontmatterBody), String(trimmedAfterClosingFence))
    }

    /// Extracts a `key: value` pair from minimal YAML frontmatter.
    /// Returns an empty-string value for `key:` with no value (e.g. the
    /// initially-written `ended_at:` line). Returns nil only if the key
    /// is absent.
    private static func valueOfFrontmatterKey(
        _ targetKey: String,
        in frontmatterYAML: String
    ) -> String? {
        for rawLine in frontmatterYAML.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            guard let colonIndex = line.firstIndex(of: ":") else { continue }
            let key = line[..<colonIndex].trimmingCharacters(in: .whitespaces)
            if key == targetKey {
                let afterColon = line[line.index(after: colonIndex)...]
                return afterColon.trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    // MARK: - Turn Blocks

    /// Walks the body of the file line-by-line, emitting a `ParsedSessionTurn`
    /// every time a new `### ` header is encountered. Multi-line user /
    /// assistant bodies are preserved verbatim.
    private static func parseTurnBlocks(fromBody body: String) -> [ParsedSessionTurn] {
        var parsedTurns: [ParsedSessionTurn] = []
        var currentHeaderLine: String?
        var currentUserLines: [String] = []
        var currentAssistantLines: [String] = []

        // Tracks which section of the current turn we're in while walking
        // the body lines. `.none` means the line belongs to neither field
        // (blank lines between header and **User:**, or between sections).
        enum SectionCursor { case none, user, assistant }
        var currentCursor: SectionCursor = .none

        func flushCurrentTurnIfAny() {
            guard let headerLine = currentHeaderLine,
                  let parsedHeader = parseTurnHeader(line: headerLine) else {
                return
            }

            let userText = currentUserLines
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let assistantText = currentAssistantLines
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            parsedTurns.append(ParsedSessionTurn(
                timestampISO8601: parsedHeader.timestampISO8601,
                userUtterance: userText,
                assistantResponse: assistantText,
                frontmostAppName: parsedHeader.frontmostAppName,
                frontmostBundleIdentifier: parsedHeader.frontmostBundleIdentifier,
                browserHostname: parsedHeader.browserHostname,
                browserToolName: parsedHeader.browserToolName,
                outputModeUsed: parsedHeader.outputModeUsed,
                turnIndexInSessionFile: parsedTurns.count
            ))

            currentHeaderLine = nil
            currentUserLines = []
            currentAssistantLines = []
            currentCursor = .none
        }

        for rawLine in body.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)

            if line.hasPrefix("### ") {
                // New turn header — flush whatever was accumulating.
                flushCurrentTurnIfAny()
                currentHeaderLine = line
                continue
            }

            if line.hasPrefix("**User:** ") {
                currentCursor = .user
                let inlineText = line.dropFirst("**User:** ".count)
                currentUserLines.append(String(inlineText))
                continue
            }

            if line.hasPrefix("**Assistant:** ") {
                currentCursor = .assistant
                let inlineText = line.dropFirst("**Assistant:** ".count)
                currentAssistantLines.append(String(inlineText))
                continue
            }

            // Continuation line — append to whichever section we're in.
            // Lines before we've seen a header or between sections get
            // dropped, which matches the writer's output shape.
            switch currentCursor {
            case .user:
                currentUserLines.append(line)
            case .assistant:
                currentAssistantLines.append(line)
            case .none:
                break
            }
        }

        flushCurrentTurnIfAny()
        return parsedTurns
    }

    // MARK: - Turn Header

    private struct ParsedTurnHeader {
        let timestampISO8601: String
        let frontmostAppName: String
        let frontmostBundleIdentifier: String
        let browserHostname: String?
        let browserToolName: String?
        let outputModeUsed: String
    }

    /// Parses a single `### ` header line. Returns nil for anything that
    /// doesn't match either the legacy or new shape so malformed lines
    /// are skipped rather than crashing the parse.
    private static func parseTurnHeader(line: String) -> ParsedTurnHeader? {
        // Shared structure: `### <timestamp> [<bracketInner>] (<outputMode>)`.
        // The bracket interior is `appName` (legacy) or
        // `appName|bundleID|hostname|tool` (new).
        guard line.hasPrefix("### ") else { return nil }

        let afterMarkerPrefix = line.dropFirst("### ".count)

        guard let bracketOpenIndex = afterMarkerPrefix.firstIndex(of: "[") else {
            return nil
        }

        let timestampRaw = afterMarkerPrefix[..<bracketOpenIndex]
            .trimmingCharacters(in: .whitespaces)

        guard let bracketCloseIndex = afterMarkerPrefix.firstIndex(of: "]") else {
            return nil
        }

        let bracketInner = afterMarkerPrefix[
            afterMarkerPrefix.index(after: bracketOpenIndex)..<bracketCloseIndex
        ]

        let afterBracket = afterMarkerPrefix[afterMarkerPrefix.index(after: bracketCloseIndex)...]
        guard let parenOpenIndex = afterBracket.firstIndex(of: "("),
              let parenCloseIndex = afterBracket.firstIndex(of: ")") else {
            return nil
        }

        let outputModeRaw = afterBracket[
            afterBracket.index(after: parenOpenIndex)..<parenCloseIndex
        ]
        let outputMode = String(outputModeRaw)

        let (appName, bundleID, hostname, tool) = parseBracketInnerFields(
            bracketInner: String(bracketInner)
        )

        return ParsedTurnHeader(
            timestampISO8601: timestampRaw,
            frontmostAppName: appName,
            frontmostBundleIdentifier: bundleID,
            browserHostname: hostname,
            browserToolName: tool,
            outputModeUsed: outputMode
        )
    }

    /// Handles both legacy 1-field and new 4-field bracket interiors.
    /// Legacy returns `(appName, "", nil, nil)`; new returns all four
    /// with `"-"` in the browser slots mapped back to nil.
    private static func parseBracketInnerFields(
        bracketInner: String
    ) -> (appName: String, bundleID: String, hostname: String?, tool: String?) {
        let fields = bracketInner.split(separator: "|", omittingEmptySubsequences: false)
            .map { String($0) }

        if fields.count == 4 {
            let appName = fields[0]
            let bundleID = fields[1]
            let hostnameRaw = fields[2]
            let toolRaw = fields[3]
            let hostname = hostnameRaw == "-" || hostnameRaw.isEmpty ? nil : hostnameRaw
            let tool = toolRaw == "-" || toolRaw.isEmpty ? nil : toolRaw
            return (appName, bundleID, hostname, tool)
        }

        // Legacy single-field layout. Empty bundle ID tells the segmenter
        // to treat this session as a single group under `appName`.
        return (bracketInner, "", nil, nil)
    }
}
