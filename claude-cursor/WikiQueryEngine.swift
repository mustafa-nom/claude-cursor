//
//  WikiQueryEngine.swift
//  claude-cursor
//
//  Retrieves relevant wiki pages for a given topic and packs them into a
//  character-budgeted context bundle suitable for inclusion in a Claude
//  system prompt. Replaces the simple index-only matching that previously
//  lived on WikiManager with a richer scoring model that also considers
//  frontmatter tags, page body content, and confidence scores.
//
//  This engine is a pure read-only view over the wiki — it never writes.
//  Writes go through WikiManager / AutoResearchPipeline / WikiPageGenerator.
//

import Foundation

// MARK: - Result Models

/// Result of a wiki query — the packed context bundle plus metadata about
/// which pages were included. Callers can use the metadata for logging,
/// telemetry, or to show a "sources consulted" indicator in the UI.
struct WikiQueryResult {
    /// Concatenated, character-budgeted content suitable for embedding in
    /// a Claude system prompt. Empty string when no pages matched.
    let contextBundle: String

    /// Filenames (within `pages/`) that contributed to the bundle, in the
    /// order they appear.
    let includedPageFilenames: [String]

    /// Total character count of contextBundle. Always ≤ the caller's
    /// requested maxCharacters.
    let totalCharacterCount: Int

    /// Keywords that drove this query. Echoed back so callers can log the
    /// effective query without having to retain the original keyword list.
    let queryKeywords: [String]

    /// True when the query matched pages but the character budget forced
    /// truncation of at least one page or exclusion of at least one page.
    /// Callers can use this to decide whether to raise the budget or
    /// request a follow-up with different keywords.
    let wasBudgetConstrained: Bool
}

/// One scored match. Used internally to rank pages before packing them into
/// a bundle. Exposed publicly via `findRelevantPages` for callers that want
/// to make their own selection decisions.
struct WikiRelevanceMatch {
    let pageFilename: String
    let pageTitle: String
    let pageType: String
    let relevanceScore: Double
    let confidence: Double
    let characterCount: Int
}

// MARK: - Query Engine

/// Pure read-only retrieval over the wiki's index.md and pages/ directory.
/// Intended to be created once and reused across many queries — the engine
/// itself holds no state between calls.
@MainActor
final class WikiQueryEngine {

    private let wikiManager: WikiManager

    /// Weight applied when a keyword appears in a page title. Title matches
    /// are the strongest signal because titles are hand-curated by the LLM
    /// during page generation.
    private let titleMatchWeight: Double = 4.0

    /// Weight applied when a keyword appears in a frontmatter tag. Tags are
    /// also curated, so strong signal, but typically shorter than titles.
    private let tagMatchWeight: Double = 3.0

    /// Weight applied when a keyword appears in the index summary line.
    private let summaryMatchWeight: Double = 2.0

    /// Weight applied per body occurrence of a keyword. Body matches are
    /// noisier (common words appear everywhere) so we give them less
    /// per-hit weight but allow them to accumulate.
    private let bodyMatchWeight: Double = 0.25

    /// Cap on body matches counted per page. Prevents one page with many
    /// incidental mentions from dominating the ranking.
    private let maxBodyMatchesCountedPerPage: Int = 20

    /// Minimum score a page must reach to be considered a match. Filters
    /// out pages that only brushed up against one weak body occurrence.
    private let minRelevanceScoreThreshold: Double = 1.0

    /// Hard cap on how many pages the engine will open and read during a
    /// single query. Keeps query latency bounded when the wiki grows large.
    private let maxPagesToScanPerQuery: Int = 50

    init(wikiManager: WikiManager) {
        self.wikiManager = wikiManager
    }

    // MARK: - Public API

    /// Builds a topic-matched, character-budgeted context bundle. Returns a
    /// `WikiQueryResult` with the bundle string and metadata. Safe to call
    /// from any main-actor context; fast enough for synchronous use on the
    /// hot path (tutor observation, answer generation).
    func buildContextBundle(
        forTopicKeywords topicKeywords: [String],
        maxCharacters: Int
    ) -> WikiQueryResult {
        let emptyResult = WikiQueryResult(
            contextBundle: "",
            includedPageFilenames: [],
            totalCharacterCount: 0,
            queryKeywords: topicKeywords,
            wasBudgetConstrained: false
        )

        let normalizedKeywords = normalizeKeywords(topicKeywords)
        guard !normalizedKeywords.isEmpty, maxCharacters > 0 else {
            return emptyResult
        }

        let rankedMatches = findRelevantPages(
            matchingKeywords: normalizedKeywords,
            maxPagesToReturn: maxPagesToScanPerQuery
        )
        guard !rankedMatches.isEmpty else {
            return emptyResult
        }

        return packMatchedPagesIntoBudgetedBundle(
            rankedMatches: rankedMatches,
            maxCharacters: maxCharacters,
            queryKeywords: normalizedKeywords
        )
    }

    /// Scans the wiki for pages matching the given keywords and returns
    /// them ranked by relevance. Does not read bodies until a page's
    /// index/frontmatter signal has already scored above the minimum —
    /// this keeps disk I/O bounded even for large wikis.
    func findRelevantPages(
        matchingKeywords normalizedKeywords: [String],
        maxPagesToReturn: Int
    ) -> [WikiRelevanceMatch] {
        guard !normalizedKeywords.isEmpty else { return [] }

        let indexEntries = wikiManager.readIndex()
        guard !indexEntries.isEmpty else { return [] }

        var provisionalMatches: [WikiRelevanceMatch] = []

        for indexEntry in indexEntries {
            let pageFilename = filenameForIndexEntry(indexEntry)
            guard wikiManager.pageExists(filename: pageFilename) else { continue }

            // Index-level signal first — title + summary + category.
            let indexOnlyScore = scoreFromIndexMetadata(
                indexEntry: indexEntry,
                normalizedKeywords: normalizedKeywords
            )

            // Open the page only if we already have some index signal OR if
            // title/summary are so short they provide little surface area.
            let shouldOpenPageBodyForScoring = indexOnlyScore > 0 ||
                (indexEntry.title.count + indexEntry.summary.count < 30)

            guard shouldOpenPageBodyForScoring else { continue }

            guard let pageContent = try? wikiManager.readPage(filename: pageFilename) else {
                continue
            }

            let frontmatterMetadata = wikiManager.parseFrontmatter(from: pageContent)
            let pageBodyText = extractBodyWithoutFrontmatter(fromPageContent: pageContent)

            let tagScore = scoreFromFrontmatterTags(
                frontmatterMetadata: frontmatterMetadata,
                normalizedKeywords: normalizedKeywords
            )
            let bodyScore = scoreFromBodyOccurrences(
                pageBodyText: pageBodyText,
                normalizedKeywords: normalizedKeywords
            )

            let totalRelevanceScore = indexOnlyScore + tagScore + bodyScore
            guard totalRelevanceScore >= minRelevanceScoreThreshold else { continue }

            let pageConfidence = frontmatterMetadata?.confidence ?? 0.5
            let pageType = frontmatterMetadata?.type ?? "unknown"
            let pageTitle = frontmatterMetadata?.title ?? indexEntry.title

            provisionalMatches.append(WikiRelevanceMatch(
                pageFilename: pageFilename,
                pageTitle: pageTitle,
                pageType: pageType,
                relevanceScore: totalRelevanceScore,
                confidence: pageConfidence,
                characterCount: pageContent.count
            ))
        }

        // Sort by blended score: relevance * (0.5 + 0.5*confidence). A
        // high-confidence page wins ties against a similarly-relevant
        // speculative page.
        provisionalMatches.sort { leftMatch, rightMatch in
            let leftBlended = leftMatch.relevanceScore * (0.5 + 0.5 * leftMatch.confidence)
            let rightBlended = rightMatch.relevanceScore * (0.5 + 0.5 * rightMatch.confidence)
            return leftBlended > rightBlended
        }

        return Array(provisionalMatches.prefix(maxPagesToReturn))
    }

    // MARK: - Scoring

    private func scoreFromIndexMetadata(
        indexEntry: WikiIndexEntry,
        normalizedKeywords: [String]
    ) -> Double {
        var score: Double = 0

        let lowercasedTitle = indexEntry.title.lowercased()
        let lowercasedSummary = indexEntry.summary.lowercased()

        for keyword in normalizedKeywords {
            if lowercasedTitle.contains(keyword) {
                score += titleMatchWeight
            }
            if lowercasedSummary.contains(keyword) {
                score += summaryMatchWeight
            }
        }

        return score
    }

    private func scoreFromFrontmatterTags(
        frontmatterMetadata: WikiPageMetadata?,
        normalizedKeywords: [String]
    ) -> Double {
        guard let metadata = frontmatterMetadata, !metadata.tags.isEmpty else {
            return 0
        }
        let lowercasedTags = metadata.tags.map { $0.lowercased() }
        var score: Double = 0
        for keyword in normalizedKeywords {
            if lowercasedTags.contains(where: { $0.contains(keyword) }) {
                score += tagMatchWeight
            }
        }
        return score
    }

    private func scoreFromBodyOccurrences(
        pageBodyText: String,
        normalizedKeywords: [String]
    ) -> Double {
        let lowercasedBody = pageBodyText.lowercased()
        var totalHitsCounted = 0

        for keyword in normalizedKeywords {
            guard !keyword.isEmpty else { continue }
            let hitsForThisKeyword = countNonOverlappingOccurrences(
                of: keyword,
                in: lowercasedBody
            )
            totalHitsCounted += min(hitsForThisKeyword, maxBodyMatchesCountedPerPage)
            if totalHitsCounted >= maxBodyMatchesCountedPerPage {
                break
            }
        }

        return Double(min(totalHitsCounted, maxBodyMatchesCountedPerPage)) * bodyMatchWeight
    }

    // MARK: - Bundle Packing

    private func packMatchedPagesIntoBudgetedBundle(
        rankedMatches: [WikiRelevanceMatch],
        maxCharacters: Int,
        queryKeywords: [String]
    ) -> WikiQueryResult {
        var budgetedContextParts: [String] = []
        var includedFilenames: [String] = []
        var totalCharactersUsed = 0
        var wasBudgetConstrained = false

        for match in rankedMatches {
            let remainingBudget = maxCharacters - totalCharactersUsed
            if remainingBudget <= 200 {
                // Not enough room for any meaningful page — stop.
                wasBudgetConstrained = true
                break
            }

            guard let pageContent = try? wikiManager.readPage(filename: match.pageFilename) else {
                continue
            }

            // Drop the YAML frontmatter from the embedded copy — the LLM
            // doesn't need the machinery, just the page body.
            let bodyOnly = extractBodyWithoutFrontmatter(fromPageContent: pageContent)
            let headerLine = "--- Wiki: \(match.pageTitle) (confidence \(formatConfidence(match.confidence))) ---"

            if bodyOnly.count + headerLine.count + 2 <= remainingBudget {
                let pageSection = "\(headerLine)\n\(bodyOnly)"
                budgetedContextParts.append(pageSection)
                includedFilenames.append(match.pageFilename)
                totalCharactersUsed += pageSection.count + 2  // +2 for joiner newlines
            } else {
                // Truncate the body to fit. Keep the header intact.
                let truncatedBody = truncateBodyToFitRemainingBudget(
                    body: bodyOnly,
                    remainingBudget: remainingBudget - headerLine.count - 2,
                    charactersUsedForTruncationIndicator: "\n\n[…truncated to fit context budget]".count
                )
                guard !truncatedBody.isEmpty else {
                    wasBudgetConstrained = true
                    break
                }
                let pageSection = "\(headerLine)\n\(truncatedBody)\n\n[…truncated to fit context budget]"
                budgetedContextParts.append(pageSection)
                includedFilenames.append(match.pageFilename)
                totalCharactersUsed += pageSection.count + 2
                wasBudgetConstrained = true
                break
            }
        }

        if rankedMatches.count > includedFilenames.count {
            wasBudgetConstrained = true
        }

        let bundleText = budgetedContextParts.joined(separator: "\n\n")

        return WikiQueryResult(
            contextBundle: bundleText,
            includedPageFilenames: includedFilenames,
            totalCharacterCount: bundleText.count,
            queryKeywords: queryKeywords,
            wasBudgetConstrained: wasBudgetConstrained
        )
    }

    // MARK: - Helpers

    /// Normalizes a raw keyword list: lowercases, trims punctuation and
    /// whitespace, removes duplicates, drops empty/very-short entries that
    /// would match too broadly (e.g., "a", "to").
    /// Short tool/framework names that must survive keyword normalization
    /// even though they're under 3 characters.
    private static let shortToolNamesAllowlist: Set<String> = [
        "git", "go", "npm", "vim", "vs", "ai", "css", "sql", "api",
        "aws", "gcp", "cli", "ssh", "tls", "jwt", "ui", "ux", "ci",
        "cd", "db", "os", "ip", "id"
    ]

    private func normalizeKeywords(_ rawKeywords: [String]) -> [String] {
        var seenKeywords: Set<String> = []
        var normalizedKeywords: [String] = []
        for rawKeyword in rawKeywords {
            let trimmed = rawKeyword
                .lowercased()
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: .punctuationCharacters)
            guard !trimmed.isEmpty else { continue }
            let meetsLengthOrAllowlist = trimmed.count >= 3 ||
                Self.shortToolNamesAllowlist.contains(trimmed)
            guard meetsLengthOrAllowlist else { continue }
            if seenKeywords.insert(trimmed).inserted {
                normalizedKeywords.append(trimmed)
            }
        }
        return normalizedKeywords
    }

    private func filenameForIndexEntry(_ indexEntry: WikiIndexEntry) -> String {
        let rawPath = indexEntry.pagePath
        // Index entries store paths like "pages/foo.md" but WikiManager
        // methods expect bare filenames under the pages/ directory.
        if rawPath.hasPrefix("pages/") {
            return String(rawPath.dropFirst("pages/".count))
        }
        return (rawPath as NSString).lastPathComponent
    }

    private func extractBodyWithoutFrontmatter(fromPageContent pageContent: String) -> String {
        let contentLines = pageContent.components(separatedBy: "\n")
        guard contentLines.first?.trimmingCharacters(in: .whitespaces) == "---" else {
            return pageContent
        }

        // Find the closing --- delimiter and return everything after it.
        for lineIndex in 1..<contentLines.count {
            if contentLines[lineIndex].trimmingCharacters(in: .whitespaces) == "---" {
                let bodyLines = contentLines.dropFirst(lineIndex + 1)
                return bodyLines
                    .joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        // Malformed frontmatter (no closing delimiter) — return original.
        return pageContent
    }

    private func countNonOverlappingOccurrences(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty, !haystack.isEmpty else { return 0 }
        var occurrenceCount = 0
        var searchStartIndex = haystack.startIndex
        while let foundRange = haystack.range(of: needle, range: searchStartIndex..<haystack.endIndex) {
            occurrenceCount += 1
            searchStartIndex = foundRange.upperBound
            if occurrenceCount >= maxBodyMatchesCountedPerPage {
                break
            }
        }
        return occurrenceCount
    }

    /// Cuts `body` to fit within `remainingBudget` characters, preferring
    /// to break on a paragraph or sentence boundary so the truncated text
    /// still reads cleanly.
    private func truncateBodyToFitRemainingBudget(
        body: String,
        remainingBudget: Int,
        charactersUsedForTruncationIndicator: Int
    ) -> String {
        let availableCharacters = remainingBudget - charactersUsedForTruncationIndicator
        guard availableCharacters > 100 else { return "" }
        guard body.count > availableCharacters else { return body }

        let truncationEndOffset = body.index(
            body.startIndex,
            offsetBy: availableCharacters,
            limitedBy: body.endIndex
        ) ?? body.endIndex
        let hardTruncated = String(body[..<truncationEndOffset])

        // Prefer paragraph break, then sentence break, then word break.
        if let lastParagraphBreak = hardTruncated.range(of: "\n\n", options: .backwards) {
            return String(hardTruncated[..<lastParagraphBreak.lowerBound])
        }
        if let lastSentenceBreak = hardTruncated.range(of: ". ", options: .backwards) {
            return String(hardTruncated[..<lastSentenceBreak.upperBound])
        }
        if let lastSpace = hardTruncated.lastIndex(of: " ") {
            return String(hardTruncated[..<lastSpace])
        }
        return hardTruncated
    }

    private func formatConfidence(_ confidence: Double) -> String {
        let clamped = min(max(confidence, 0.0), 1.0)
        return String(format: "%.2f", clamped)
    }
}
