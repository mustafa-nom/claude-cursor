//
//  SessionCompressor.swift
//  claude-cursor
//
//  Turns a raw session log into a compressed wiki page. Feeds the session's
//  turn history to Claude with a system prompt that asks for durable
//  observations the user would want to remember across sessions — not a
//  verbose transcript summary. Output is written as a wiki page in
//  pages/session-<id>.md and indexed so `WikiQueryEngine` can find it later.
//

import Foundation

/// Compressed session observation returned by Claude. The compressor parses
/// Claude's JSON response into this structure and uses it to build a
/// well-formatted wiki page.
struct CompressedSessionObservation: Codable {
    /// One-line headline describing what the user did in this session.
    let sessionHeadline: String

    /// 3–10 durable observations — things Claude should remember about the
    /// user's preferences, workflow, or the tool they were working with.
    /// These become bullet points in the wiki page body.
    let durableObservations: [String]

    /// Task outcomes observed during the session — what the user tried,
    /// whether it worked, and what lessons can be drawn for future help.
    let taskOutcomes: [TaskOutcome]?

    /// Suggested tags for the wiki page's frontmatter (e.g., ["figma",
    /// "auto-layout", "prototyping"]). The compressor truncates the list
    /// before writing to keep the page's tag array manageable.
    let suggestedTags: [String]
}

/// A single task outcome from a session — captures what the user was
/// trying to do and whether the approach worked.
struct TaskOutcome: Codable {
    let task: String
    let outcome: String
    let whatWorked: String?
    let whatFailed: String?
}

// MARK: - Compressor

@MainActor
final class SessionCompressor {

    private let claudeAPIForCompression: ClaudeAPI
    private let wikiManager: WikiManager

    /// Upper bound on how many turns from the session get fed to Claude.
    /// Sessions longer than this get truncated to the most recent N turns —
    /// which usually capture the session's final state and takeaways.
    private let maxTurnsSentToCompressor: Int = 30

    /// Maximum tags retained on the compressed wiki page. Prevents Claude
    /// from producing sprawling tag lists that hurt query precision.
    private let maxTagsRetainedPerPage: Int = 6

    init(claudeAPIForCompression: ClaudeAPI, wikiManager: WikiManager) {
        self.claudeAPIForCompression = claudeAPIForCompression
        self.wikiManager = wikiManager
    }

    // MARK: - Public API

    /// Compresses a session into a wiki page. Writes the page to `pages/`
    /// and adds an entry to `index.md`. Logs the ingest to `log.md`.
    /// Best-effort — if Claude fails or returns unparseable output, logs
    /// the failure and returns without writing a page so the raw session
    /// log is still available for manual review.
    func compressSessionIntoWikiPage(
        sessionMetadata: ObservedSessionMetadata,
        observedTurns: [ObservedSessionTurn],
        sessionLogFileURL: URL
    ) async {
        let turnsToSend = Array(observedTurns.suffix(maxTurnsSentToCompressor))
        let promptTranscript = buildTranscriptStringForPrompt(turns: turnsToSend)

        let systemPrompt = """
        You are a session compressor. You turn a user's session log into a compact
        observation page for a personal knowledge wiki. The wiki is read by an
        AI companion later to remember how the user works.

        Output ONLY a JSON object matching this exact schema — no preamble, no markdown
        fences, no commentary:

        {
          "sessionHeadline": "One-line summary, max 80 chars, no trailing period",
          "durableObservations": [
            "Observation 1: concrete, actionable, written as a fact about the user",
            "Observation 2: ...",
            "... 3 to 10 observations total"
          ],
          "taskOutcomes": [
            {
              "task": "Brief description of what the user was trying to do",
              "outcome": "success or failure or partial",
              "whatWorked": "What approach or advice succeeded (if any)",
              "whatFailed": "What didn't work or what the user struggled with (if any)"
            }
          ],
          "suggestedTags": ["tag1", "tag2", "tag3"]
        }

        Rules for durableObservations:
        - Focus on the USER: their preferences, goals, pain points, workflows.
        - Skip pleasantries, greetings, and off-topic chatter.
        - Skip the assistant's responses unless they reflect a choice the user made.
        - Each observation should still be useful a week from now.
        - Do not invent details. If something isn't in the transcript, don't claim it.

        Rules for taskOutcomes:
        - Include 0 to 5 task outcomes. Only include them if there's clear evidence.
        - A "success" means the user got what they wanted. A "failure" means they
          didn't, complained, or re-asked. "partial" means they got partway there.
        - whatWorked/whatFailed should be specific enough that a future assistant
          can learn from them (e.g. "using auto-layout in Figma" not just "layout").
        """

        let userPromptBody = """
        Session metadata:
        - Started: \(sessionMetadata.startedAtISO8601)
        - Ended: \(sessionMetadata.endedAtISO8601 ?? "in progress")
        - Apps seen: \(sessionMetadata.frontmostAppsSeen.joined(separator: ", "))
        - Turns: \(sessionMetadata.turnCount)

        Session transcript:

        \(promptTranscript)

        Produce the JSON observation now.
        """

        let claudeRawResponse: String
        do {
            let chatResult = try await claudeAPIForCompression.analyzeImage(
                images: [],
                systemPrompt: systemPrompt,
                conversationHistory: [],
                userPrompt: userPromptBody
            )
            claudeRawResponse = chatResult.text
        } catch {
            print("⚠️ SessionCompressor: Claude compression failed — \(error)")
            wikiManager.appendLogEntry(
                type: "session-compress-failed",
                title: sessionMetadata.sessionIdentifier,
                details: "Error: \(error.localizedDescription)"
            )
            return
        }

        guard let compressed = decodeCompressedObservation(fromClaudeResponse: claudeRawResponse) else {
            print("⚠️ SessionCompressor: could not decode compressed observation from response:\n\(claudeRawResponse.prefix(500))")
            wikiManager.appendLogEntry(
                type: "session-compress-parse-failed",
                title: sessionMetadata.sessionIdentifier,
                details: "Response was not valid JSON matching the schema"
            )
            return
        }

        writeCompressedObservationAsWikiPage(
            compressed: compressed,
            sessionMetadata: sessionMetadata,
            sessionLogFileURL: sessionLogFileURL
        )
    }

    // MARK: - Cold Start Recap

    /// Generates a brief recap of a prior session, suitable to greet the
    /// user on return after a 4+ hour gap. The recap is surfaced by
    /// CompanionManager when it detects a long inter-session gap.
    ///
    /// Returns nil if the session file can't be read or Claude fails —
    /// callers should treat recap as a nice-to-have, never a blocker.
    func generateColdStartRecap(fromMostRecentSessionFileURL sessionFileURL: URL) async -> String? {
        guard let sessionFileContents = try? String(contentsOf: sessionFileURL, encoding: .utf8) else {
            return nil
        }

        // Trim the transcript if it's huge so we stay well under model limits.
        let trimmedSessionContents = String(sessionFileContents.suffix(12_000))

        let systemPrompt = """
        You write short, warm recaps of a user's last session. Address the user directly
        in second person. 2–3 sentences max. No preamble, no bullet points, no headings.
        Focus on WHAT they were doing and the last concrete thing they tried, so they
        can pick back up naturally. Do not mention that you are an AI or describe yourself.
        """

        let userPrompt = """
        Here is the user's most recent session log. Write the recap now.

        \(trimmedSessionContents)
        """

        do {
            let recapResult = try await claudeAPIForCompression.analyzeImage(
                images: [],
                systemPrompt: systemPrompt,
                conversationHistory: [],
                userPrompt: userPrompt
            )
            let cleaned = recapResult.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return cleaned.isEmpty ? nil : cleaned
        } catch {
            print("⚠️ SessionCompressor: cold-start recap failed — \(error)")
            return nil
        }
    }

    // MARK: - Prompt Building

    private func buildTranscriptStringForPrompt(turns: [ObservedSessionTurn]) -> String {
        var transcriptLines: [String] = []
        for turn in turns {
            let appContext = turn.frontmostAppName.isEmpty ? "" : " [\(turn.frontmostAppName)]"
            transcriptLines.append("User\(appContext): \(turn.userUtterance)")
            transcriptLines.append("Assistant: \(turn.assistantResponse)")
            transcriptLines.append("---")
        }
        return transcriptLines.joined(separator: "\n")
    }

    // MARK: - Response Decoding

    private func decodeCompressedObservation(fromClaudeResponse rawResponse: String) -> CompressedSessionObservation? {
        // Strip potential markdown code fences.
        var candidateJSONString = rawResponse
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if candidateJSONString.hasPrefix("```json") {
            candidateJSONString = String(candidateJSONString.dropFirst("```json".count))
        } else if candidateJSONString.hasPrefix("```") {
            candidateJSONString = String(candidateJSONString.dropFirst(3))
        }
        if candidateJSONString.hasSuffix("```") {
            candidateJSONString = String(candidateJSONString.dropLast(3))
        }
        candidateJSONString = candidateJSONString.trimmingCharacters(in: .whitespacesAndNewlines)

        // Narrow to the outermost object braces in case Claude prefixed with prose.
        if let firstBraceIndex = candidateJSONString.firstIndex(of: "{"),
           let lastBraceIndex = candidateJSONString.lastIndex(of: "}"),
           firstBraceIndex < lastBraceIndex {
            candidateJSONString = String(candidateJSONString[firstBraceIndex...lastBraceIndex])
        }

        guard let jsonData = candidateJSONString.data(using: .utf8) else {
            return nil
        }

        return try? JSONDecoder().decode(CompressedSessionObservation.self, from: jsonData)
    }

    // MARK: - Wiki Page Writing

    private func writeCompressedObservationAsWikiPage(
        compressed: CompressedSessionObservation,
        sessionMetadata: ObservedSessionMetadata,
        sessionLogFileURL: URL
    ) {
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withFullDate]
        let dateString = dateFormatter.string(from: Date())

        let cappedTags = Array(compressed.suggestedTags.prefix(maxTagsRetainedPerPage))

        let observationBulletList = compressed.durableObservations
            .map { "- \($0)" }
            .joined(separator: "\n")

        let appsSeenLine: String
        if sessionMetadata.frontmostAppsSeen.isEmpty {
            appsSeenLine = "(none recorded)"
        } else {
            appsSeenLine = sessionMetadata.frontmostAppsSeen.joined(separator: ", ")
        }

        var taskOutcomesSection = ""
        if let outcomes = compressed.taskOutcomes, !outcomes.isEmpty {
            let outcomeLines = outcomes.map { outcome in
                var line = "- **\(outcome.task)** — \(outcome.outcome)"
                if let worked = outcome.whatWorked, !worked.isEmpty {
                    line += "\n  - Worked: \(worked)"
                }
                if let failed = outcome.whatFailed, !failed.isEmpty {
                    line += "\n  - Failed: \(failed)"
                }
                return line
            }.joined(separator: "\n")
            taskOutcomesSection = """

            ## Task Outcomes

            \(outcomeLines)
            """
        }

        let pageBody = """
        # \(compressed.sessionHeadline)

        **Session:** \(sessionMetadata.sessionIdentifier)
        **Apps:** \(appsSeenLine)
        **Turns:** \(sessionMetadata.turnCount)

        ## Observations

        \(observationBulletList)
        \(taskOutcomesSection)

        ## Source

        See the raw session log at `raw/sessions/\(sessionLogFileURL.lastPathComponent)`.
        """

        let pageMetadata = WikiPageMetadata(
            type: "session",
            title: compressed.sessionHeadline,
            sources: ["raw/sessions/\(sessionLogFileURL.lastPathComponent)"],
            dateCreated: dateString,
            dateModified: dateString,
            confidence: 0.7,
            tags: cappedTags
        )

        let pageContent = wikiManager.buildPageContent(metadata: pageMetadata, body: pageBody)
        let pageFilename = "session-\(sessionMetadata.sessionIdentifier).md"

        do {
            try wikiManager.writePage(filename: pageFilename, content: pageContent)
        } catch {
            print("⚠️ SessionCompressor: failed to write wiki page \(pageFilename) — \(error)")
            return
        }

        do {
            try wikiManager.addIndexEntry(WikiIndexEntry(
                pagePath: "pages/\(pageFilename)",
                title: compressed.sessionHeadline,
                summary: appsSeenLine,
                category: "sessions"
            ))
        } catch {
            print("⚠️ SessionCompressor: failed to index session page \(pageFilename) — \(error)")
        }

        wikiManager.appendLogEntry(
            type: "session-compressed",
            title: sessionMetadata.sessionIdentifier,
            details: "Wrote pages/\(pageFilename) with \(compressed.durableObservations.count) observations"
        )

        print("📚 SessionCompressor: wrote \(pageFilename) with \(compressed.durableObservations.count) observations")
    }
}
