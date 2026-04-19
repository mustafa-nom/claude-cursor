//
//  AutoResearchPipeline.swift
//  claude-cursor
//
//  Ingests docs for a given topic into the wiki's raw/sources/ directory.
//  Tries curated documentation sources first (user-editable JSON file with
//  defaults for target apps) and falls back to Tavily web search if none of
//  the curated sources match. Content extraction runs through the Cloudflare
//  Worker's /fetch-url route so no external HTTP calls happen in-process.
//
//  The pipeline is stateless — each call to ingestTopic builds a fresh set of
//  raw source files. Produces normalized markdown with frontmatter pointing
//  back to the original URL and fetch date so downstream ingest stages (the
//  wiki page generator) can cite provenance.
//

import Foundation

// MARK: - Configuration Model

/// A single entry in the user-editable doc-sources.json file. Represents a
/// curated documentation source for one target app. `topicKeywords` determine
/// which ingest requests route to this source — matched against the caller's
/// topic string with case-insensitive substring comparison.
struct CuratedDocumentationSource: Codable {
    /// Display name, e.g. "DaVinci Resolve Documentation".
    let name: String

    /// Keywords that activate this source. If any keyword appears in the
    /// caller's topic string (case-insensitive), the source is tried.
    let topicKeywords: [String]

    /// URL template with `{query}` placeholder. The placeholder is replaced
    /// with the URL-encoded query string. If no placeholder is present, the
    /// URL is used verbatim and the query is ignored.
    let searchURLTemplate: String

    /// Optional list of static pages to include alongside any search result.
    /// Useful for pinning a table-of-contents page or top-level landing page.
    let alwaysIncludePageURLs: [String]?
}

/// Wrapper struct for the top-level doc-sources.json file.
struct CuratedDocumentationSourcesFile: Codable {
    let sources: [CuratedDocumentationSource]
}

// MARK: - Result Models

/// A raw source file that was ingested into the wiki. The caller (the wiki
/// page generator) uses this to know what sources it has available when
/// composing the structured wiki page.
struct IngestedRawSource {
    /// Filename within raw/sources/ where the content was written.
    let rawSourceFilename: String

    /// Display-friendly title extracted from the source, or the URL if no
    /// title could be derived.
    let sourceTitle: String

    /// Original URL the content came from.
    let sourceURL: String

    /// Which path produced this source — curated or Tavily fallback.
    let sourceOrigin: IngestedRawSourceOrigin

    /// Character count of the extracted body content (excludes frontmatter).
    let extractedBodyCharacterCount: Int
}

/// Where a raw source came from in the research pipeline.
enum IngestedRawSourceOrigin: String {
    case curatedDocumentationSource
    case tavilyWebSearchFallback
}

/// Errors surfaced from the pipeline. Callers should show user-friendly
/// messages when these escape to the UI.
enum AutoResearchPipelineError: LocalizedError {
    case invalidWorkerBaseURL(attemptedURL: String)
    case workerWebSearchFailed(statusCode: Int, body: String)
    case workerFetchURLFailed(statusCode: Int, body: String)
    case noSourcesYieldedContent(topic: String)

    var errorDescription: String? {
        switch self {
        case .invalidWorkerBaseURL(let attemptedURL):
            return "Auto-research: worker base URL is invalid: \(attemptedURL)"
        case .workerWebSearchFailed(let statusCode, let body):
            return "Auto-research: Tavily search failed (HTTP \(statusCode)): \(body)"
        case .workerFetchURLFailed(let statusCode, let body):
            return "Auto-research: content fetch failed (HTTP \(statusCode)): \(body)"
        case .noSourcesYieldedContent(let topic):
            return "Auto-research: no content found for topic '\(topic)'"
        }
    }
}

// MARK: - Pipeline

/// Orchestrates the curated-first, Tavily-fallback research flow. One
/// instance can be reused across multiple ingest calls — it holds no
/// per-request state. All persistence goes through the injected WikiManager
/// so file layout stays consistent with the rest of the wiki system.
@MainActor
final class AutoResearchPipeline {

    private let wikiManager: WikiManager
    private let workerBaseURL: String
    private let urlSession: URLSession

    /// Maximum number of curated pages to fetch per ingest call. Keeps the
    /// total worker request volume predictable when a topic matches several
    /// curated sources.
    private let maxCuratedPagesPerIngest: Int = 5

    /// Maximum number of Tavily search results to fetch body content for.
    /// Tavily returns up to 10 results but we only need a handful to produce
    /// a useful wiki page.
    private let maxTavilyResultsToFetch: Int = 3

    /// Minimum character count for a source body to be considered useful.
    /// Guards against empty-content fetches (e.g., JS-rendered pages that
    /// respond with nearly-empty HTML).
    private let minUsefulBodyCharacterCount: Int = 400

    init(wikiManager: WikiManager, workerBaseURL: String) {
        self.wikiManager = wikiManager
        self.workerBaseURL = workerBaseURL

        let sessionConfiguration = URLSessionConfiguration.default
        sessionConfiguration.timeoutIntervalForRequest = 30
        sessionConfiguration.timeoutIntervalForResource = 90
        sessionConfiguration.urlCache = nil
        self.urlSession = URLSession(configuration: sessionConfiguration)
    }

    // MARK: - Public API

    /// Ingests documentation for the given topic. Tries curated sources
    /// first; if none match or all fail, falls back to Tavily web search.
    /// Every successfully fetched source is written to raw/sources/ with
    /// YAML frontmatter so downstream ingest stages can cite provenance.
    ///
    /// Returns the list of raw sources that were written. Throws if neither
    /// path produced any content.
    func ingestTopic(_ topic: String) async throws -> [IngestedRawSource] {
        // Ensure wiki directories exist — the pipeline may run before the
        // menu bar panel has been opened, so the wiki may not have been
        // initialized by the startup path yet.
        if !wikiManager.isInitialized {
            wikiManager.initializeIfNeeded()
        }

        let curatedSources = loadCuratedDocumentationSources()
        let matchingCuratedSources = curatedSources.filter { source in
            topicMatchesAnyKeyword(topic: topic, keywords: source.topicKeywords)
        }

        var collectedRawSources: [IngestedRawSource] = []

        // Path 1: curated sources (if any match)
        if !matchingCuratedSources.isEmpty {
            let curatedResults = await ingestFromCuratedDocumentationSources(
                matchingCuratedSources: matchingCuratedSources,
                topic: topic
            )
            collectedRawSources.append(contentsOf: curatedResults)
        }

        // Path 2: Tavily fallback (if curated yielded nothing)
        if collectedRawSources.isEmpty {
            let tavilyResults = try await ingestFromTavilyWebSearchFallback(topic: topic)
            collectedRawSources.append(contentsOf: tavilyResults)
        }

        guard !collectedRawSources.isEmpty else {
            throw AutoResearchPipelineError.noSourcesYieldedContent(topic: topic)
        }

        wikiManager.appendLogEntry(
            type: "ingest",
            title: "auto-research: \(topic)",
            details: "Ingested \(collectedRawSources.count) source(s): " +
                     collectedRawSources.map { $0.sourceURL }.joined(separator: ", ")
        )

        return collectedRawSources
    }

    // MARK: - Curated Documentation Path

    /// Loads the user-editable doc-sources.json file from the wiki root.
    /// Seeds it with defaults on first run (DaVinci Resolve, Figma, VS Code/
    /// Cursor) so users have something meaningful out of the box. Returns
    /// an empty list if the file exists but can't be parsed — failing open
    /// so a malformed user edit doesn't break the whole pipeline.
    func loadCuratedDocumentationSources() -> [CuratedDocumentationSource] {
        let docSourcesFileURL = wikiManager.wikiRootURL.appendingPathComponent("doc-sources.json")

        if !FileManager.default.fileExists(atPath: docSourcesFileURL.path) {
            seedDefaultDocumentationSourcesFile(at: docSourcesFileURL)
        }

        guard let fileData = try? Data(contentsOf: docSourcesFileURL) else {
            print("⚠️ AutoResearchPipeline: could not read doc-sources.json")
            return []
        }

        do {
            let decoded = try JSONDecoder().decode(CuratedDocumentationSourcesFile.self, from: fileData)
            return decoded.sources
        } catch {
            print("⚠️ AutoResearchPipeline: doc-sources.json is malformed — \(error)")
            return []
        }
    }

    private func seedDefaultDocumentationSourcesFile(at fileURL: URL) {
        let defaultFile = CuratedDocumentationSourcesFile(sources: Self.defaultCuratedDocumentationSources)
        guard let encoded = try? JSONEncoder.withPrettyPrintAndSortedKeys.encode(defaultFile) else {
            print("⚠️ AutoResearchPipeline: failed to encode default doc sources")
            return
        }
        do {
            try encoded.write(to: fileURL, options: [.atomic])
            print("📚 AutoResearchPipeline: seeded doc-sources.json with defaults")
        } catch {
            print("⚠️ AutoResearchPipeline: failed to seed doc-sources.json — \(error)")
        }
    }

    private func topicMatchesAnyKeyword(topic: String, keywords: [String]) -> Bool {
        let lowercasedTopic = topic.lowercased()
        return keywords.contains { keyword in
            lowercasedTopic.contains(keyword.lowercased())
        }
    }

    private func ingestFromCuratedDocumentationSources(
        matchingCuratedSources: [CuratedDocumentationSource],
        topic: String
    ) async -> [IngestedRawSource] {
        var pagesURLsToFetch: [String] = []

        for source in matchingCuratedSources {
            // Always-include pages go first — they're the most authoritative
            // entry points and give wide topic coverage.
            if let alwaysIncludePageURLs = source.alwaysIncludePageURLs {
                pagesURLsToFetch.append(contentsOf: alwaysIncludePageURLs)
            }

            // Then the templated search URL if it has a placeholder.
            if source.searchURLTemplate.contains("{query}") {
                let urlEncodedQuery = topic.addingPercentEncoding(
                    withAllowedCharacters: .urlQueryAllowed
                ) ?? topic
                let interpolatedURL = source.searchURLTemplate
                    .replacingOccurrences(of: "{query}", with: urlEncodedQuery)
                pagesURLsToFetch.append(interpolatedURL)
            } else {
                pagesURLsToFetch.append(source.searchURLTemplate)
            }
        }

        // Dedup while preserving order — a curated source and alwaysInclude
        // list may repeat a page in practice.
        var seenURLs: Set<String> = []
        var deduplicatedURLsToFetch: [String] = []
        for pageURL in pagesURLsToFetch {
            if seenURLs.insert(pageURL).inserted {
                deduplicatedURLsToFetch.append(pageURL)
            }
        }

        let capdURLsToFetch = Array(deduplicatedURLsToFetch.prefix(maxCuratedPagesPerIngest))

        var results: [IngestedRawSource] = []
        for pageURL in capdURLsToFetch {
            do {
                let fetched = try await fetchAndNormalizePageContent(pageURL: pageURL)
                guard fetched.bodyText.count >= minUsefulBodyCharacterCount else {
                    print("📚 AutoResearchPipeline: skipping \(pageURL) — body too short (\(fetched.bodyText.count) chars)")
                    continue
                }
                let rawSource = try writeRawSourceFile(
                    fetched: fetched,
                    sourceURL: pageURL,
                    sourceOrigin: .curatedDocumentationSource,
                    topic: topic
                )
                results.append(rawSource)
            } catch {
                print("⚠️ AutoResearchPipeline: curated fetch failed for \(pageURL) — \(error)")
                continue
            }
        }

        return results
    }

    // MARK: - Tavily Fallback Path

    private func ingestFromTavilyWebSearchFallback(topic: String) async throws -> [IngestedRawSource] {
        let searchResults = try await performTavilyWebSearch(query: topic)
        let topResultsToFetch = Array(searchResults.prefix(maxTavilyResultsToFetch))

        var results: [IngestedRawSource] = []
        for searchResult in topResultsToFetch {
            do {
                let fetched = try await fetchAndNormalizePageContent(pageURL: searchResult.url)
                guard fetched.bodyText.count >= minUsefulBodyCharacterCount else {
                    print("📚 AutoResearchPipeline: Tavily result too short at \(searchResult.url)")
                    continue
                }
                let rawSource = try writeRawSourceFile(
                    fetched: fetched,
                    sourceURL: searchResult.url,
                    sourceOrigin: .tavilyWebSearchFallback,
                    topic: topic
                )
                results.append(rawSource)
            } catch {
                print("⚠️ AutoResearchPipeline: Tavily fetch failed for \(searchResult.url) — \(error)")
                continue
            }
        }

        return results
    }

    private struct TavilySearchResultItem {
        let title: String
        let url: String
        let snippet: String
    }

    private func performTavilyWebSearch(query: String) async throws -> [TavilySearchResultItem] {
        guard let webSearchRouteURL = URL(string: "\(workerBaseURL)/web-search") else {
            throw AutoResearchPipelineError.invalidWorkerBaseURL(attemptedURL: workerBaseURL)
        }

        var request = URLRequest(url: webSearchRouteURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let requestPayload: [String: Any] = [
            "query": query,
            "maxResults": 5
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: requestPayload)

        let (responseData, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AutoResearchPipelineError.workerWebSearchFailed(
                statusCode: -1,
                body: "No HTTP response"
            )
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let responseBody = String(data: responseData, encoding: .utf8) ?? "(non-utf8 body)"
            throw AutoResearchPipelineError.workerWebSearchFailed(
                statusCode: httpResponse.statusCode,
                body: responseBody
            )
        }

        guard let decodedJSON = try JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let resultsArray = decodedJSON["results"] as? [[String: Any]] else {
            return []
        }

        return resultsArray.compactMap { resultDictionary in
            guard let title = resultDictionary["title"] as? String,
                  let url = resultDictionary["url"] as? String else {
                return nil
            }
            let snippet = (resultDictionary["content"] as? String) ?? ""
            return TavilySearchResultItem(title: title, url: url, snippet: snippet)
        }
    }

    // MARK: - Content Fetch + Normalize

    private struct FetchedPageContent {
        let sourceURL: String
        let title: String
        let bodyText: String
        let contentType: String
    }

    private func fetchAndNormalizePageContent(pageURL: String) async throws -> FetchedPageContent {
        guard let fetchRouteURL = URL(string: "\(workerBaseURL)/fetch-url") else {
            throw AutoResearchPipelineError.invalidWorkerBaseURL(attemptedURL: workerBaseURL)
        }

        var request = URLRequest(url: fetchRouteURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let requestPayload: [String: Any] = ["url": pageURL]
        request.httpBody = try JSONSerialization.data(withJSONObject: requestPayload)

        let (responseData, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AutoResearchPipelineError.workerFetchURLFailed(
                statusCode: -1,
                body: "No HTTP response"
            )
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let responseBody = String(data: responseData, encoding: .utf8) ?? "(non-utf8 body)"
            throw AutoResearchPipelineError.workerFetchURLFailed(
                statusCode: httpResponse.statusCode,
                body: responseBody
            )
        }

        guard let decodedJSON = try JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let rawBody = decodedJSON["body"] as? String else {
            throw AutoResearchPipelineError.workerFetchURLFailed(
                statusCode: httpResponse.statusCode,
                body: "Response missing 'body' field"
            )
        }

        let contentType = (decodedJSON["contentType"] as? String) ?? "text/html"
        let normalizedBodyText: String
        let extractedTitle: String

        if contentType.localizedCaseInsensitiveContains("html") {
            let stripped = stripHTMLTagsAndWhitespace(htmlText: rawBody)
            normalizedBodyText = stripped.bodyText
            extractedTitle = stripped.title.isEmpty ? pageURL : stripped.title
        } else {
            normalizedBodyText = rawBody
            extractedTitle = pageURL
        }

        return FetchedPageContent(
            sourceURL: pageURL,
            title: extractedTitle,
            bodyText: normalizedBodyText,
            contentType: contentType
        )
    }

    /// Strips HTML tags and script/style content, collapses whitespace, and
    /// pulls out the <title> element if present. This is a pragmatic
    /// extractor — not a full Readability implementation — but produces
    /// clean enough text for the wiki ingest stage to summarize.
    private func stripHTMLTagsAndWhitespace(htmlText: String) -> (title: String, bodyText: String) {
        // Extract title first (before we strip everything)
        let titleText = extractHTMLTitleElement(from: htmlText) ?? ""

        var workingText = htmlText

        // Remove script and style blocks with their content
        workingText = removeHTMLTagWithContent(from: workingText, tagName: "script")
        workingText = removeHTMLTagWithContent(from: workingText, tagName: "style")
        workingText = removeHTMLTagWithContent(from: workingText, tagName: "noscript")
        workingText = removeHTMLTagWithContent(from: workingText, tagName: "svg")

        // Replace block-level tags with newlines so paragraph breaks survive
        let blockLevelTagNames = ["p", "div", "h1", "h2", "h3", "h4", "h5", "h6", "li", "br", "tr"]
        for tagName in blockLevelTagNames {
            workingText = workingText.replacingOccurrences(
                of: "</?\(tagName)[^>]*>",
                with: "\n",
                options: [.regularExpression, .caseInsensitive]
            )
        }

        // Strip all remaining tags
        workingText = workingText.replacingOccurrences(
            of: "<[^>]+>",
            with: "",
            options: .regularExpression
        )

        // Decode a handful of common HTML entities
        let htmlEntityReplacements: [(String, String)] = [
            ("&nbsp;", " "), ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
            ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"),
            ("&mdash;", "—"), ("&ndash;", "–"), ("&hellip;", "…")
        ]
        for (entity, replacement) in htmlEntityReplacements {
            workingText = workingText.replacingOccurrences(of: entity, with: replacement)
        }

        // Collapse runs of whitespace and blank lines
        workingText = workingText.replacingOccurrences(
            of: "[ \\t]+",
            with: " ",
            options: .regularExpression
        )
        workingText = workingText.replacingOccurrences(
            of: "\\n{3,}",
            with: "\n\n",
            options: .regularExpression
        )
        workingText = workingText.trimmingCharacters(in: .whitespacesAndNewlines)

        return (title: titleText, bodyText: workingText)
    }

    private func extractHTMLTitleElement(from htmlText: String) -> String? {
        guard let titleMatchRange = htmlText.range(
            of: "<title[^>]*>([\\s\\S]*?)</title>",
            options: [.regularExpression, .caseInsensitive]
        ) else {
            return nil
        }
        let titleTagContent = String(htmlText[titleMatchRange])
        let innerText = titleTagContent
            .replacingOccurrences(of: "<title[^>]*>", with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: "</title>", with: "", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return innerText
    }

    private func removeHTMLTagWithContent(from htmlText: String, tagName: String) -> String {
        return htmlText.replacingOccurrences(
            of: "<\(tagName)[^>]*>[\\s\\S]*?</\(tagName)>",
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
    }

    // MARK: - Raw Source Persistence

    /// Writes a fetched page to raw/sources/ with YAML frontmatter. Filename
    /// is derived from the topic and a content hash so repeated ingests of
    /// the same topic don't collide and so each source is uniquely addressable.
    private func writeRawSourceFile(
        fetched: FetchedPageContent,
        sourceURL: String,
        sourceOrigin: IngestedRawSourceOrigin,
        topic: String
    ) throws -> IngestedRawSource {
        let sanitizedTopic = sanitizeFilenameComponent(topic).prefix(40)
        let urlHashSuffix = String(abs(sourceURL.hashValue)).prefix(8)
        let filename = "\(sanitizedTopic)-\(urlHashSuffix).md"

        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withFullDate]
        let dateString = dateFormatter.string(from: Date())

        let frontmatter = """
        ---
        type: source
        title: \(fetched.title)
        source_url: \(sourceURL)
        source_origin: \(sourceOrigin.rawValue)
        topic: \(topic)
        date_fetched: \(dateString)
        content_type: \(fetched.contentType)
        ---

        """

        let fileContent = frontmatter + fetched.bodyText + "\n"
        try wikiManager.writeRawSource(filename: String(filename), content: fileContent)

        return IngestedRawSource(
            rawSourceFilename: String(filename),
            sourceTitle: fetched.title,
            sourceURL: sourceURL,
            sourceOrigin: sourceOrigin,
            extractedBodyCharacterCount: fetched.bodyText.count
        )
    }

    /// Turns an arbitrary string into a safe filename component by lowercasing,
    /// replacing whitespace and punctuation with dashes, and collapsing runs
    /// of dashes. Returns "untitled" if the input is empty after sanitization.
    private func sanitizeFilenameComponent(_ input: String) -> String {
        let lowercased = input.lowercased()
        var sanitized = ""
        for character in lowercased {
            if character.isLetter || character.isNumber {
                sanitized.append(character)
            } else {
                sanitized.append("-")
            }
        }
        while sanitized.contains("--") {
            sanitized = sanitized.replacingOccurrences(of: "--", with: "-")
        }
        sanitized = sanitized.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return sanitized.isEmpty ? "untitled" : sanitized
    }

    // MARK: - Default Documentation Sources

    /// Seeds doc-sources.json with curated defaults for the three demo apps.
    /// Users can edit this file in their App Support directory to add their
    /// own sources or tune keywords. These defaults intentionally prefer
    /// official documentation over community blog posts.
    private static let defaultCuratedDocumentationSources: [CuratedDocumentationSource] = [
        CuratedDocumentationSource(
            name: "DaVinci Resolve Documentation",
            topicKeywords: ["davinci", "resolve", "color grading", "fusion", "fairlight"],
            searchURLTemplate: "https://documents.blackmagicdesign.com/UserManuals/DaVinci_Resolve_18_Reference_Manual.pdf",
            alwaysIncludePageURLs: [
                "https://www.blackmagicdesign.com/products/davinciresolve/training"
            ]
        ),
        CuratedDocumentationSource(
            name: "Figma Help Center",
            topicKeywords: ["figma", "auto layout", "component", "prototype"],
            searchURLTemplate: "https://help.figma.com/hc/en-us/search?query={query}",
            alwaysIncludePageURLs: [
                "https://help.figma.com/hc/en-us/categories/360002042614-Design",
                "https://help.figma.com/hc/en-us/categories/360002051613-Prototyping"
            ]
        ),
        CuratedDocumentationSource(
            name: "Visual Studio Code Documentation",
            topicKeywords: ["vscode", "vs code", "visual studio code", "cursor editor"],
            searchURLTemplate: "https://code.visualstudio.com/docs",
            alwaysIncludePageURLs: [
                "https://code.visualstudio.com/docs/editor/codebasics",
                "https://code.visualstudio.com/docs/getstarted/keybindings"
            ]
        )
    ]
}

// MARK: - JSONEncoder Convenience

private extension JSONEncoder {
    /// Pretty-printed encoder with sorted keys — makes doc-sources.json easy
    /// to hand-edit and diff when users modify it.
    static var withPrettyPrintAndSortedKeys: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}
