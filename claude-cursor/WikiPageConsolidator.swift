//
//  WikiPageConsolidator.swift
//  claude-cursor
//
//  Merges duplicate or closely related wiki pages into a single
//  consolidated page. Uses Claude to intelligently combine content,
//  keeping the best information from each source page. Triggered
//  after session compression when the new page overlaps with existing
//  pages.
//

import Foundation

@MainActor
final class WikiPageConsolidator {

    private let claudeAPIForConsolidation: ClaudeAPI
    private let wikiManager: WikiManager

    /// Maximum number of pages that can be merged in a single operation.
    /// Keeps the prompt size bounded.
    private let maximumPagesToMergeAtOnce: Int = 4

    /// Maximum characters of page content sent to Claude per page.
    private let maximumCharactersPerPageForPrompt: Int = 6000

    init(claudeAPIForConsolidation: ClaudeAPI, wikiManager: WikiManager) {
        self.claudeAPIForConsolidation = claudeAPIForConsolidation
        self.wikiManager = wikiManager
    }

    /// Checks if the given page has duplicates and merges them if found.
    /// Safe to call speculatively — no-ops when no duplicates exist.
    func consolidateIfDuplicatesExist(forPageFilename pageFilename: String) async {
        let relatedPages = wikiManager.findDuplicateOrRelatedPages(
            forPageFilename: pageFilename
        )
        guard !relatedPages.isEmpty else { return }

        let allPageFilenames = [pageFilename] + Array(relatedPages.prefix(maximumPagesToMergeAtOnce - 1))
        await mergePages(pageFilenames: allPageFilenames)
    }

    /// Merges multiple wiki pages into a single consolidated page.
    /// Keeps the first page's filename and deletes the rest.
    private func mergePages(pageFilenames: [String]) async {
        guard pageFilenames.count >= 2 else { return }

        var pageContents: [(filename: String, content: String, metadata: WikiPageMetadata)] = []
        for filename in pageFilenames {
            guard let content = try? wikiManager.readPage(filename: filename) else { continue }
            guard let metadata = wikiManager.parseFrontmatter(from: content) else { continue }
            pageContents.append((filename: filename, content: content, metadata: metadata))
        }

        guard pageContents.count >= 2 else { return }

        let targetFilename = pageContents[0].filename

        let systemPrompt = """
        You are a wiki page consolidator. You merge multiple related wiki pages \
        into a single comprehensive page. Keep the best, most current, and most \
        useful information from each source page.

        Output ONLY a JSON object matching this exact schema — no preamble, no \
        markdown fences, no commentary:

        {
          "mergedTitle": "Best title for the consolidated page (max 80 chars)",
          "mergedBody": "Full markdown body of the merged page",
          "mergedTags": ["tag1", "tag2", "tag3"],
          "confidence": 0.8
        }

        Rules:
        - Deduplicate information. If two pages say the same thing, keep the \
          more detailed/recent version.
        - Preserve task outcomes and observations — these are valuable history.
        - The merged body should be well-organized with clear headings.
        - Confidence should reflect how reliable the merged information is \
          (0.0 to 1.0). Higher if sources agree, lower if they conflict.
        """

        var sourcePagesText = ""
        for (index, page) in pageContents.enumerated() {
            let bodyText = extractBodyWithoutFrontmatter(from: page.content)
            let truncatedBody = String(bodyText.prefix(maximumCharactersPerPageForPrompt))
            sourcePagesText += """
            --- Page \(index + 1): \(page.metadata.title) ---
            Tags: \(page.metadata.tags.joined(separator: ", "))
            Confidence: \(page.metadata.confidence)

            \(truncatedBody)

            """
        }

        let userPrompt = """
        Merge these \(pageContents.count) wiki pages into one consolidated page:

        \(sourcePagesText)

        Produce the JSON now.
        """

        do {
            let claudeResponse = try await claudeAPIForConsolidation.analyzeImage(
                images: [],
                systemPrompt: systemPrompt,
                userPrompt: userPrompt,
                maxTokens: 4096
            )

            guard let mergedPage = parseMergedPageResponse(claudeResponse.text) else {
                print("⚠️ WikiPageConsolidator: failed to parse merge response")
                return
            }

            let dateFormatter = ISO8601DateFormatter()
            dateFormatter.formatOptions = [.withFullDate]
            let dateString = dateFormatter.string(from: Date())

            let allSources = pageContents.flatMap { $0.metadata.sources }
            let cappedTags = Array(mergedPage.mergedTags.prefix(6))

            let metadata = WikiPageMetadata(
                type: pageContents[0].metadata.type,
                title: mergedPage.mergedTitle,
                sources: allSources,
                dateCreated: pageContents[0].metadata.dateCreated,
                dateModified: dateString,
                confidence: max(0.0, min(1.0, mergedPage.confidence)),
                tags: cappedTags
            )

            let pageContent = wikiManager.buildPageContent(
                metadata: metadata,
                body: mergedPage.mergedBody
            )

            try wikiManager.writePage(filename: targetFilename, content: pageContent)

            // Delete the duplicate pages (skip the first one — that's our target)
            for duplicatePage in pageContents.dropFirst() {
                do {
                    try wikiManager.deletePage(filename: duplicatePage.filename)
                    print("📚 WikiPageConsolidator: deleted merged duplicate \(duplicatePage.filename)")
                } catch {
                    print("⚠️ WikiPageConsolidator: failed to delete \(duplicatePage.filename) — \(error)")
                }
            }

            wikiManager.appendLogEntry(
                type: "pages-consolidated",
                title: mergedPage.mergedTitle,
                details: "Merged \(pageContents.count) pages into \(targetFilename)"
            )

            print("📚 WikiPageConsolidator: merged \(pageContents.count) pages into \(targetFilename)")

        } catch {
            print("⚠️ WikiPageConsolidator: merge failed — \(error)")
        }
    }

    // MARK: - Response Parsing

    private struct MergedPageResponse: Codable {
        let mergedTitle: String
        let mergedBody: String
        let mergedTags: [String]
        let confidence: Double
    }

    private func parseMergedPageResponse(_ rawResponse: String) -> MergedPageResponse? {
        var working = rawResponse.trimmingCharacters(in: .whitespacesAndNewlines)

        // Strip code fences
        if working.hasPrefix("```") {
            if let firstNewline = working.firstIndex(of: "\n") {
                working = String(working[working.index(after: firstNewline)...])
            }
            if working.hasSuffix("```") {
                working = String(working.dropLast(3))
            }
            working = working.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Extract JSON object
        if let openBrace = working.firstIndex(of: "{"),
           let closeBrace = working.lastIndex(of: "}"),
           openBrace < closeBrace {
            working = String(working[openBrace...closeBrace])
        }

        guard let data = working.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(MergedPageResponse.self, from: data)
    }

    private func extractBodyWithoutFrontmatter(from pageContent: String) -> String {
        let lines = pageContent.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else {
            return pageContent
        }

        var closingDashIndex: Int?
        for (index, line) in lines.enumerated() where index > 0 {
            if line.trimmingCharacters(in: .whitespaces) == "---" {
                closingDashIndex = index
                break
            }
        }

        guard let closingIndex = closingDashIndex, closingIndex + 1 < lines.count else {
            return pageContent
        }

        return lines[(closingIndex + 1)...].joined(separator: "\n")
    }
}
