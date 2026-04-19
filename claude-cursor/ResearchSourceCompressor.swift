//
//  ResearchSourceCompressor.swift
//  claude-cursor
//
//  Bridges the research ingest layer (AutoResearchPipeline, which writes raw
//  documentation fetches to raw/sources/) to the query layer (WikiQueryEngine,
//  which only walks pages/ + index.md). Without this bridge, researched
//  material lives on disk but never surfaces in query_wiki results.
//
//  Mirrors SessionCompressor's pattern: feed Claude a JSON schema, parse the
//  structured reply, write a single wiki page under pages/ with YAML
//  frontmatter, add an index entry, and append a log line. Best-effort — any
//  failure is logged and swallowed so a broken compression never blocks the
//  caller's UX. The raw sources stay on disk either way.
//

import CryptoKit
import Foundation

/// Compressed research page returned by Claude. Parsed from the JSON reply
/// and used to build the final wiki page written to pages/.
struct CompressedResearchPage: Codable {
    /// Short headline for the page — used as the wiki page's `title` field
    /// and surfaced in the index entry.
    let pageTitle: String

    /// One-line summary shown in index.md so `WikiQueryEngine` can match on
    /// it cheaply before opening the page body.
    let oneLineSummary: String

    /// Full markdown body (300–1500 words). Should cite source URLs inline as
    /// markdown links so the user can trace claims back to their origin.
    let body: String

    /// Tags for the frontmatter's `tags:` array. Used by
    /// `WikiQueryEngine.scoreFromFrontmatterTags`.
    let suggestedTags: [String]

    /// Claude's self-reported confidence in the page's accuracy (0.0–1.0).
    /// Weighted into `WikiQueryEngine`'s ranking.
    let confidence: Double
}

// MARK: - Compressor

@MainActor
final class ResearchSourceCompressor {

    private let claudeAPIForCompression: ClaudeAPI
    private let wikiManager: WikiManager

    /// Maximum tags retained on the compressed wiki page. Prevents Claude
    /// from producing sprawling tag lists that hurt query precision.
    private let maxTagsRetainedPerPage: Int = 6

    /// Upper bound on the character count of a single source body included
    /// in the compression prompt. Keeps the prompt under Claude's context
    /// window even when Tavily returns an unusually long page. Sources are
    /// truncated (with an ellipsis marker) rather than dropped.
    private let maxCharactersPerSourceInPrompt: Int = 8_000

    /// Total upper bound on characters across all sources in the prompt.
    /// Extra sources beyond this are dropped entirely (the pipeline already
    /// caps source count, so this is a belt-and-suspenders guard).
    private let maxTotalSourceCharactersInPrompt: Int = 30_000

    init(
        claudeAPIForCompression: ClaudeAPI,
        wikiManager: WikiManager
    ) {
        self.claudeAPIForCompression = claudeAPIForCompression
        self.wikiManager = wikiManager
    }

    // MARK: - Public API

    /// Reads the given raw source files, asks Claude to distill them into a
    /// structured wiki page for `topic`, and writes the result to
    /// `pages/research-<slug>-<hash>.md` with an index entry and log line.
    ///
    /// Best-effort: errors are logged and swallowed rather than thrown. Callers
    /// do not depend on page availability — the raw sources are already on
    /// disk and the user can retry by running research on the same topic
    /// again.
    func compressResearchSourcesIntoWikiPage(
        forTopic topic: String,
        ingestedRawSources: [IngestedRawSource]
    ) async {
        guard !ingestedRawSources.isEmpty else {
            print("⚠️ ResearchSourceCompressor: no ingested sources for topic '\(topic)' — skipping compression")
            return
        }

        let sourceReadResults = readIngestedSourceBodies(ingestedRawSources: ingestedRawSources)
        guard !sourceReadResults.isEmpty else {
            print("⚠️ ResearchSourceCompressor: all source reads failed for topic '\(topic)' — skipping compression")
            wikiManager.appendLogEntry(
                type: "research-compress-failed",
                title: topic,
                details: "No readable sources among \(ingestedRawSources.count) raw files"
            )
            return
        }

        // Check if a page already exists for this topic (same SHA256 slug).
        // If so, include its content in the prompt so Claude can produce an
        // updated version rather than a duplicate.
        let tentativePageFilename = buildStableResearchPageFilename(
            topic: topic,
            ingestedRawSources: ingestedRawSources
        )
        let existingPageContent: String?
        if wikiManager.pageExists(filename: tentativePageFilename),
           let content = try? wikiManager.readPage(filename: tentativePageFilename) {
            existingPageContent = content
        } else {
            existingPageContent = nil
        }

        let systemPrompt = compressionSystemPrompt
        var userPrompt = buildCompressionUserPrompt(
            topic: topic,
            sourceReadResults: sourceReadResults
        )
        if let existingContent = existingPageContent {
            let existingBodyTruncated = String(existingContent.prefix(6000))
            userPrompt += """

            --- Existing Wiki Page for This Topic ---
            A page already exists for this topic. Update and improve it with the
            new sources above rather than starting from scratch. Keep any valuable
            information from the existing page that isn't covered by the new sources.

            \(existingBodyTruncated)
            --- End Existing Page ---
            """
        }

        let claudeRawResponse: String
        do {
            let chatResult = try await claudeAPIForCompression.analyzeImage(
                images: [],
                systemPrompt: systemPrompt,
                conversationHistory: [],
                userPrompt: userPrompt
            )
            claudeRawResponse = chatResult.text
        } catch {
            print("⚠️ ResearchSourceCompressor: Claude compression failed for topic '\(topic)' — \(error)")
            wikiManager.appendLogEntry(
                type: "research-compress-failed",
                title: topic,
                details: "Error: \(error.localizedDescription)"
            )
            return
        }

        guard let compressed = decodeCompressedResearchPage(fromClaudeResponse: claudeRawResponse) else {
            print("⚠️ ResearchSourceCompressor: could not decode research page for topic '\(topic)':\n\(claudeRawResponse.prefix(500))")
            wikiManager.appendLogEntry(
                type: "research-compress-parse-failed",
                title: topic,
                details: "Response was not valid JSON matching the schema"
            )
            return
        }

        writeCompressedResearchPageToWiki(
            compressed: compressed,
            topic: topic,
            ingestedRawSources: ingestedRawSources,
            pageFilename: tentativePageFilename,
            existingPageContent: existingPageContent
        )
    }

    // MARK: - Prompt

    private var compressionSystemPrompt: String {
        """
        You are a research page compressor. You turn fetched documentation
        excerpts into a single compact wiki page for a personal knowledge wiki.
        The wiki is read by an AI companion later so it can answer the user's
        questions with grounded context.

        Output ONLY a JSON object matching this exact schema — no preamble, no
        markdown code fences, no commentary outside the JSON:

        {
          "pageTitle": "Short headline, max 80 chars, Title Case, no trailing period",
          "oneLineSummary": "One sentence describing what this page covers, max 160 chars",
          "body": "Full markdown content, 300–1500 words, with citations",
          "suggestedTags": ["tag1", "tag2", "tag3"],
          "confidence": 0.0
        }

        Rules for the body:
        - Use markdown headings (##, ###) and bullets where they aid scanning.
        - Cite every concrete claim inline as a markdown link back to the
          source URL you got it from — e.g. "By default, Resolve's color page
          uses the Davinci Wide Gamut timeline space ([source](https://...))".
        - Do NOT invent facts that are not in the provided sources. If the
          sources disagree, note the disagreement rather than picking a side.
        - Keep a neutral, reference-manual tone — not marketing copy.
        - Prefer dense, scannable structure over long prose paragraphs so
          keyword retrieval works well later.

        Rules for confidence:
        - 0.8–0.9 when all sources come from official curated documentation
          and agree with each other.
        - 0.5–0.7 when sources are a mix of official docs and general-web
          results, or when coverage is partial.
        - 0.3–0.4 when sources are sparse, tangential, or conflict.

        Rules for suggestedTags:
        - 3 to 6 short lowercase tags — product names, feature names, workflow
          nouns. Avoid vague tags like "help" or "guide".
        """
    }

    private func buildCompressionUserPrompt(
        topic: String,
        sourceReadResults: [ResearchSourceReadResult]
    ) -> String {
        var promptSections: [String] = []
        promptSections.append("Topic: \(topic)")
        promptSections.append("")
        promptSections.append("Sources (\(sourceReadResults.count)):")
        promptSections.append("")

        var totalCharactersIncluded = 0
        for (sourceIndex, readResult) in sourceReadResults.enumerated() {
            let remainingBudget = maxTotalSourceCharactersInPrompt - totalCharactersIncluded
            guard remainingBudget > 500 else {
                promptSections.append("(\(sourceReadResults.count - sourceIndex) additional sources omitted to stay within prompt budget)")
                break
            }

            let truncatedBody = truncateSourceBodyForPrompt(
                readResult.bodyText,
                perSourceLimit: min(maxCharactersPerSourceInPrompt, remainingBudget)
            )
            totalCharactersIncluded += truncatedBody.count

            promptSections.append("--- Source \(sourceIndex + 1) ---")
            promptSections.append("Title: \(readResult.sourceTitle)")
            promptSections.append("URL: \(readResult.sourceURL)")
            promptSections.append("Origin: \(readResult.sourceOrigin.rawValue)")
            promptSections.append("")
            promptSections.append(truncatedBody)
            promptSections.append("")
        }

        promptSections.append("Produce the JSON research page now.")
        return promptSections.joined(separator: "\n")
    }

    private func truncateSourceBodyForPrompt(
        _ body: String,
        perSourceLimit: Int
    ) -> String {
        guard body.count > perSourceLimit else { return body }
        let prefix = body.prefix(perSourceLimit)
        return String(prefix) + "\n\n[... truncated ...]"
    }

    // MARK: - Source Reading

    /// Represents a raw source file loaded from disk, with the frontmatter
    /// stripped so Claude only sees the body text.
    private struct ResearchSourceReadResult {
        let rawSourceFilename: String
        let sourceTitle: String
        let sourceURL: String
        let sourceOrigin: IngestedRawSourceOrigin
        let bodyText: String
    }

    private func readIngestedSourceBodies(
        ingestedRawSources: [IngestedRawSource]
    ) -> [ResearchSourceReadResult] {
        var readResults: [ResearchSourceReadResult] = []
        for ingestedSource in ingestedRawSources {
            guard let fullFileContent = try? wikiManager.readRawSource(
                filename: ingestedSource.rawSourceFilename
            ) else {
                print("⚠️ ResearchSourceCompressor: could not read raw source \(ingestedSource.rawSourceFilename)")
                continue
            }
            let bodyText = stripYAMLFrontmatter(fromFileContent: fullFileContent)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !bodyText.isEmpty else { continue }

            readResults.append(ResearchSourceReadResult(
                rawSourceFilename: ingestedSource.rawSourceFilename,
                sourceTitle: ingestedSource.sourceTitle,
                sourceURL: ingestedSource.sourceURL,
                sourceOrigin: ingestedSource.sourceOrigin,
                bodyText: bodyText
            ))
        }
        return readResults
    }

    /// Drops a leading `---\n...\n---\n` YAML frontmatter block if present,
    /// returning the remaining body. AutoResearchPipeline writes every raw
    /// source with this exact shape, but we defensively handle files that
    /// don't have frontmatter (manually-added sources, for example).
    private func stripYAMLFrontmatter(fromFileContent fileContent: String) -> String {
        guard fileContent.hasPrefix("---\n") else { return fileContent }
        let afterOpeningMarker = fileContent.dropFirst("---\n".count)
        guard let closingRange = afterOpeningMarker.range(of: "\n---\n") else {
            return fileContent
        }
        return String(afterOpeningMarker[closingRange.upperBound...])
    }

    // MARK: - Response Decoding

    private func decodeCompressedResearchPage(
        fromClaudeResponse rawResponse: String
    ) -> CompressedResearchPage? {
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

        if let firstBraceIndex = candidateJSONString.firstIndex(of: "{"),
           let lastBraceIndex = candidateJSONString.lastIndex(of: "}"),
           firstBraceIndex < lastBraceIndex {
            candidateJSONString = String(candidateJSONString[firstBraceIndex...lastBraceIndex])
        }

        guard let jsonData = candidateJSONString.data(using: .utf8) else {
            return nil
        }

        return try? JSONDecoder().decode(CompressedResearchPage.self, from: jsonData)
    }

    // MARK: - Wiki Page Writing

    private func writeCompressedResearchPageToWiki(
        compressed: CompressedResearchPage,
        topic: String,
        ingestedRawSources: [IngestedRawSource],
        pageFilename: String,
        existingPageContent: String?
    ) {
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withFullDate]
        let dateString = dateFormatter.string(from: Date())

        let cappedTags = Array(compressed.suggestedTags.prefix(maxTagsRetainedPerPage))

        let sourcesReferencedInFrontmatter = ingestedRawSources.map {
            "raw/sources/\($0.rawSourceFilename)"
        }

        // Preserve original creation date when updating an existing page.
        let effectiveDateCreated: String
        if let existingContent = existingPageContent,
           let existingMetadata = wikiManager.parseFrontmatter(from: existingContent),
           !existingMetadata.dateCreated.isEmpty {
            effectiveDateCreated = existingMetadata.dateCreated
        } else {
            effectiveDateCreated = dateString
        }

        let pageMetadata = WikiPageMetadata(
            type: "research",
            title: compressed.pageTitle,
            sources: sourcesReferencedInFrontmatter,
            dateCreated: effectiveDateCreated,
            dateModified: dateString,
            confidence: clampConfidence(compressed.confidence),
            tags: cappedTags
        )

        let pageContent = wikiManager.buildPageContent(metadata: pageMetadata, body: compressed.body)

        do {
            try wikiManager.writePage(filename: pageFilename, content: pageContent)
        } catch {
            print("⚠️ ResearchSourceCompressor: failed to write \(pageFilename) — \(error)")
            return
        }

        // Only add an index entry if this is a new page. Updating an
        // existing page doesn't need a second index line.
        if existingPageContent == nil {
            do {
                try wikiManager.addIndexEntry(WikiIndexEntry(
                    pagePath: "pages/\(pageFilename)",
                    title: compressed.pageTitle,
                    summary: compressed.oneLineSummary,
                    category: "research"
                ))
            } catch {
                print("⚠️ ResearchSourceCompressor: failed to index \(pageFilename) — \(error)")
            }
        }

        let totalBodyCharacterCount = ingestedRawSources
            .map(\.extractedBodyCharacterCount)
            .reduce(0, +)
        wikiManager.appendLogEntry(
            type: "research-ingest",
            title: topic,
            details: "Wrote pages/\(pageFilename) from \(ingestedRawSources.count) sources (\(totalBodyCharacterCount) chars)"
        )

        print("📚 ResearchSourceCompressor: wrote \(pageFilename) for topic '\(topic)' from \(ingestedRawSources.count) sources")
    }

    // MARK: - Filename Construction

    /// Builds a stable, collision-resistant filename for the compressed
    /// research page. The digest is derived from SHA256 over the sorted,
    /// joined source URLs so repeated ingests of the same topic on the same
    /// source set produce the same filename — avoids duplicate pages across
    /// app restarts (unlike `String.hashValue`, which is runtime-randomized).
    private func buildStableResearchPageFilename(
        topic: String,
        ingestedRawSources: [IngestedRawSource]
    ) -> String {
        let sanitizedTopicSlug = sanitizeFilenameComponent(topic).prefix(40)

        let sortedJoinedURLs = ingestedRawSources
            .map(\.sourceURL)
            .sorted()
            .joined(separator: "|")

        let digestBytes = SHA256.hash(data: Data(sortedJoinedURLs.utf8))
        let digestHex = digestBytes.compactMap { String(format: "%02x", $0) }.joined()
        let stableDigestShort = String(digestHex.prefix(8))

        return "research-\(sanitizedTopicSlug)-\(stableDigestShort).md"
    }

    /// Sanitizes a freeform string into a filename-safe slug: lowercase,
    /// hyphens between words, alphanumerics only. Mirrors the slug logic
    /// already used in `AutoResearchPipeline.sanitizeFilenameComponent`.
    private func sanitizeFilenameComponent(_ rawComponent: String) -> String {
        let lowercased = rawComponent.lowercased()
        var sanitizedCharacters: [Character] = []
        var previousCharacterWasHyphen = false
        for character in lowercased {
            if character.isLetter || character.isNumber {
                sanitizedCharacters.append(character)
                previousCharacterWasHyphen = false
            } else if !previousCharacterWasHyphen {
                sanitizedCharacters.append("-")
                previousCharacterWasHyphen = true
            }
        }
        // Trim leading/trailing hyphens so we don't produce filenames like
        // "-foo-bar-.md".
        return String(sanitizedCharacters)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    /// Clamps a raw confidence value to the [0.0, 1.0] range so a stray
    /// Claude reply can't produce an out-of-range frontmatter field that
    /// confuses `WikiQueryEngine`'s score blending.
    private func clampConfidence(_ rawConfidence: Double) -> Double {
        if rawConfidence.isNaN || rawConfidence.isInfinite { return 0.5 }
        return max(0.0, min(1.0, rawConfidence))
    }
}
