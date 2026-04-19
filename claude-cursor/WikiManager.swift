//
//  WikiManager.swift
//  claude-cursor
//
//  Swift-native wiki manager for ClaudeCursor's knowledge pipeline.
//  Follows the llm-wiki pattern: raw sources → LLM-maintained wiki pages
//  → index for query-time retrieval. All files are plain markdown with
//  YAML frontmatter, stored in ~/Library/Application Support/ClaudeCursor/wiki/.
//
//  The wiki directory structure:
//    wiki/
//      index.md          — catalog of all wiki pages with one-line summaries
//      log.md            — chronological record of ingests, queries, lint passes
//      schema.md         — conventions and page formats for the LLM
//      pages/            — LLM-generated wiki pages (entities, concepts, summaries)
//      raw/              — immutable source documents (articles, transcripts, screenshots)
//        sources/        — ingested source files
//        sessions/       — session observation logs from the observer agent
//        automation/     — automation action audit logs
//

import Combine
import Foundation

/// Metadata parsed from a wiki page's YAML frontmatter block.
struct WikiPageMetadata {
    let type: String        // e.g. "entity", "concept", "source-summary", "session"
    let title: String
    let sources: [String]   // source file references
    let dateCreated: String
    let dateModified: String
    let confidence: Double  // 0.0–1.0, how confident the LLM is in the content
    let tags: [String]
}

/// A single entry in the wiki's index.md file.
struct WikiIndexEntry {
    let pagePath: String    // relative path from wiki/ root, e.g. "pages/davinci-resolve-basics.md"
    let title: String
    let summary: String     // one-line description
    let category: String    // e.g. "concepts", "entities", "sources"
}

/// Manages the on-disk wiki directory, file I/O, frontmatter parsing,
/// and index maintenance. Does NOT perform LLM operations — that's the
/// responsibility of AutoResearchPipeline and WikiQueryEngine which use
/// this manager for storage.
@MainActor
final class WikiManager: ObservableObject {

    /// Whether the wiki directory has been initialized and is ready for use.
    @Published private(set) var isInitialized = false

    /// Total number of pages in the wiki (derived from index.md).
    @Published private(set) var pageCount = 0

    /// Root directory for the wiki: ~/Library/Application Support/ClaudeCursor/wiki/
    let wikiRootURL: URL

    /// Subdirectory for LLM-generated wiki pages.
    var pagesDirectoryURL: URL { wikiRootURL.appendingPathComponent("pages") }

    /// Subdirectory for immutable raw source documents.
    var rawDirectoryURL: URL { wikiRootURL.appendingPathComponent("raw") }

    /// Subdirectory for ingested source files within raw/.
    var rawSourcesDirectoryURL: URL { rawDirectoryURL.appendingPathComponent("sources") }

    /// Subdirectory for session observation logs within raw/.
    var rawSessionsDirectoryURL: URL { rawDirectoryURL.appendingPathComponent("sessions") }

    /// Subdirectory for automation audit logs within raw/.
    var rawAutomationDirectoryURL: URL { rawDirectoryURL.appendingPathComponent("automation") }

    /// Path to the wiki index file.
    var indexFileURL: URL { wikiRootURL.appendingPathComponent("index.md") }

    /// Path to the chronological log file.
    var logFileURL: URL { wikiRootURL.appendingPathComponent("log.md") }

    /// Path to the schema/conventions file.
    var schemaFileURL: URL { wikiRootURL.appendingPathComponent("schema.md") }

    private let fileManager = FileManager.default

    init() {
        let appSupportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        wikiRootURL = appSupportURL
            .appendingPathComponent("ClaudeCursor")
            .appendingPathComponent("wiki")
    }

    // MARK: - Initialization

    /// Creates the wiki directory structure if it doesn't exist, and seeds
    /// the schema, index, and log files. Safe to call multiple times — only
    /// creates what's missing.
    func initializeIfNeeded() {
        let directoriesToCreate = [
            wikiRootURL,
            pagesDirectoryURL,
            rawDirectoryURL,
            rawSourcesDirectoryURL,
            rawSessionsDirectoryURL,
            rawAutomationDirectoryURL
        ]

        for directoryURL in directoriesToCreate {
            if !fileManager.fileExists(atPath: directoryURL.path) {
                do {
                    try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
                    print("📚 WikiManager: created directory \(directoryURL.lastPathComponent)")
                } catch {
                    print("⚠️ WikiManager: failed to create directory \(directoryURL.path): \(error)")
                    return
                }
            }
        }

        // Seed files only if they don't already exist (never overwrite user edits)
        seedFileIfMissing(at: schemaFileURL, content: Self.defaultSchemaContent)
        seedFileIfMissing(at: indexFileURL, content: Self.defaultIndexContent)
        seedFileIfMissing(at: logFileURL, content: Self.defaultLogContent)

        refreshPageCount()
        isInitialized = true
        print("📚 WikiManager: initialized at \(wikiRootURL.path) (\(pageCount) pages)")
    }

    // MARK: - Page Operations

    /// Writes a wiki page to the pages/ directory. Creates the file if it
    /// doesn't exist, overwrites if it does. The caller is responsible for
    /// generating the markdown content with proper YAML frontmatter.
    func writePage(filename: String, content: String) throws {
        let pageURL = pagesDirectoryURL.appendingPathComponent(filename)
        try content.write(to: pageURL, atomically: true, encoding: .utf8)
        refreshPageCount()
    }

    /// Reads a wiki page's full content (frontmatter + body).
    func readPage(filename: String) throws -> String {
        let pageURL = pagesDirectoryURL.appendingPathComponent(filename)
        return try String(contentsOf: pageURL, encoding: .utf8)
    }

    /// Deletes a wiki page from `pages/`. Returns true if the file existed and was removed.
    /// Used by one-shot cleanup and `WikiPageConsolidator` after merges.
    @discardableResult
    func deletePage(filename: String) throws -> Bool {
        let pageURL = pagesDirectoryURL.appendingPathComponent(filename)
        guard fileManager.fileExists(atPath: pageURL.path) else { return false }
        try fileManager.removeItem(at: pageURL)
        refreshPageCount()
        return true
    }

    /// Lists all wiki page filenames in the pages/ directory.
    func listPages() -> [String] {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: pagesDirectoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return contents
            .filter { $0.pathExtension == "md" }
            .map { $0.lastPathComponent }
    }

    /// Checks whether a page with the given filename exists.
    func pageExists(filename: String) -> Bool {
        fileManager.fileExists(atPath: pagesDirectoryURL.appendingPathComponent(filename).path)
    }

    /// Finds pages that are likely duplicates of or closely related to
    /// the given page, based on overlapping tags and similar titles.
    /// Returns filenames (not full paths) of related pages, excluding
    /// the target page itself.
    func findDuplicateOrRelatedPages(
        forPageFilename targetFilename: String
    ) -> [String] {
        guard let targetContent = try? readPage(filename: targetFilename) else { return [] }
        guard let targetMetadata = parseFrontmatter(from: targetContent) else { return [] }
        let targetTags = Set(targetMetadata.tags.map { $0.lowercased() })
        let targetTitleWords = Set(
            targetMetadata.title.lowercased()
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { $0.count >= 3 }
        )

        guard !targetTags.isEmpty || !targetTitleWords.isEmpty else { return [] }

        var relatedPageFilenames: [String] = []
        let allPages = listPages()

        for pageFilename in allPages {
            guard pageFilename != targetFilename else { continue }
            guard let pageContent = try? readPage(filename: pageFilename) else { continue }
            guard let pageMetadata = parseFrontmatter(from: pageContent) else { continue }

            let pageTags = Set(pageMetadata.tags.map { $0.lowercased() })
            let sharedTagCount = targetTags.intersection(pageTags).count

            let pageTitleWords = Set(
                pageMetadata.title.lowercased()
                    .components(separatedBy: .whitespacesAndNewlines)
                    .filter { $0.count >= 3 }
            )
            let sharedTitleWords = targetTitleWords.intersection(pageTitleWords).count
            let titleUnionCount = max(1, targetTitleWords.union(pageTitleWords).count)
            let titleOverlapRatio = Double(sharedTitleWords) / Double(titleUnionCount)

            if sharedTagCount >= 2 || titleOverlapRatio > 0.5 {
                relatedPageFilenames.append(pageFilename)
            }
        }

        return relatedPageFilenames
    }

    // MARK: - Raw Source Operations

    /// Writes a raw source file. These are immutable — the LLM reads from
    /// them but should never modify them.
    func writeRawSource(filename: String, content: String) throws {
        let sourceURL = rawSourcesDirectoryURL.appendingPathComponent(filename)
        try content.write(to: sourceURL, atomically: true, encoding: .utf8)
    }

    /// Reads the full contents of a raw source file (frontmatter + body).
    /// `ResearchSourceCompressor` calls this to pull freshly-ingested pages
    /// into its compression prompt before bridging them into `pages/`.
    func readRawSource(filename: String) throws -> String {
        let sourceURL = rawSourcesDirectoryURL.appendingPathComponent(filename)
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }

    /// Writes a session observation log to raw/sessions/.
    func writeSessionLog(filename: String, content: String) throws {
        let sessionURL = rawSessionsDirectoryURL.appendingPathComponent(filename)
        try content.write(to: sessionURL, atomically: true, encoding: .utf8)
    }

    /// Writes an automation audit log to raw/automation/.
    func writeAutomationLog(filename: String, content: String) throws {
        let automationURL = rawAutomationDirectoryURL.appendingPathComponent(filename)
        try content.write(to: automationURL, atomically: true, encoding: .utf8)
    }

    // MARK: - Index Operations

    /// Reads and parses the index.md file into structured entries.
    func readIndex() -> [WikiIndexEntry] {
        guard let indexContent = try? String(contentsOf: indexFileURL, encoding: .utf8) else {
            return []
        }
        return parseIndexEntries(from: indexContent)
    }

    /// Appends a new entry to the index.md file under the specified category.
    /// If the category section doesn't exist, creates it.
    func addIndexEntry(_ entry: WikiIndexEntry) throws {
        var indexContent = (try? String(contentsOf: indexFileURL, encoding: .utf8)) ?? Self.defaultIndexContent
        let entryLine = "- [\(entry.title)](\(entry.pagePath)) — \(entry.summary)"
        let categoryHeader = "## \(entry.category)"

        if let categoryRange = indexContent.range(of: categoryHeader) {
            // Find the end of the category section (next ## or end of file)
            let searchStartIndex = categoryRange.upperBound
            let remainingContent = indexContent[searchStartIndex...]
            if let nextSectionRange = remainingContent.range(of: "\n## ") {
                // Insert before the next section
                indexContent.insert(contentsOf: "\n\(entryLine)", at: nextSectionRange.lowerBound)
            } else {
                // Append at end of file
                indexContent.append("\n\(entryLine)")
            }
        } else {
            // Category doesn't exist — create it at the end
            indexContent.append("\n\n\(categoryHeader)\n\n\(entryLine)")
        }

        try indexContent.write(to: indexFileURL, atomically: true, encoding: .utf8)
    }

    // MARK: - Log Operations

    /// Appends a timestamped entry to log.md.
    func appendLogEntry(type: String, title: String, details: String = "") {
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withFullDate]
        let dateString = dateFormatter.string(from: Date())

        var logLine = "## [\(dateString)] \(type) | \(title)"
        if !details.isEmpty {
            logLine += "\n\(details)"
        }
        logLine += "\n"

        guard var logContent = try? String(contentsOf: logFileURL, encoding: .utf8) else { return }
        logContent.append("\n\(logLine)")
        try? logContent.write(to: logFileURL, atomically: true, encoding: .utf8)
    }

    // MARK: - Frontmatter Parsing

    /// Parses YAML frontmatter from a markdown string. Returns nil if no
    /// frontmatter block is found (delimited by --- on its own line).
    func parseFrontmatter(from markdownContent: String) -> WikiPageMetadata? {
        let lines = markdownContent.components(separatedBy: "\n")

        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else {
            return nil
        }

        // Find the closing --- delimiter
        var closingDelimiterLineIndex: Int?
        for lineIndex in 1..<lines.count {
            if lines[lineIndex].trimmingCharacters(in: .whitespaces) == "---" {
                closingDelimiterLineIndex = lineIndex
                break
            }
        }

        guard let endIndex = closingDelimiterLineIndex else { return nil }

        let frontmatterLines = lines[1..<endIndex]
        var frontmatterDictionary: [String: String] = [:]

        for line in frontmatterLines {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            frontmatterDictionary[key] = value
        }

        // Parse tags and sources from comma-separated bracket syntax: [tag1, tag2]
        let tags = parseListValue(frontmatterDictionary["tags"] ?? "")
        let sources = parseListValue(frontmatterDictionary["sources"] ?? "")

        return WikiPageMetadata(
            type: frontmatterDictionary["type"] ?? "unknown",
            title: frontmatterDictionary["title"] ?? "Untitled",
            sources: sources,
            dateCreated: frontmatterDictionary["date_created"] ?? "",
            dateModified: frontmatterDictionary["date_modified"] ?? "",
            confidence: Double(frontmatterDictionary["confidence"] ?? "0.5") ?? 0.5,
            tags: tags
        )
    }

    /// Builds a complete wiki page string with YAML frontmatter and body content.
    func buildPageContent(metadata: WikiPageMetadata, body: String) -> String {
        let sourcesString = metadata.sources.isEmpty ? "[]" : "[\(metadata.sources.joined(separator: ", "))]"
        let tagsString = metadata.tags.isEmpty ? "[]" : "[\(metadata.tags.joined(separator: ", "))]"

        return """
        ---
        type: \(metadata.type)
        title: \(metadata.title)
        sources: \(sourcesString)
        date_created: \(metadata.dateCreated)
        date_modified: \(metadata.dateModified)
        confidence: \(metadata.confidence)
        tags: \(tagsString)
        ---

        \(body)
        """
    }

    // MARK: - Private Helpers

    private func seedFileIfMissing(at fileURL: URL, content: String) {
        guard !fileManager.fileExists(atPath: fileURL.path) else { return }
        do {
            try content.write(to: fileURL, atomically: true, encoding: .utf8)
            print("📚 WikiManager: seeded \(fileURL.lastPathComponent)")
        } catch {
            print("⚠️ WikiManager: failed to seed \(fileURL.lastPathComponent): \(error)")
        }
    }

    private func refreshPageCount() {
        pageCount = listPages().count
    }

    /// Parses a bracketed comma-separated list like "[tag1, tag2, tag3]" into an array.
    private func parseListValue(_ value: String) -> [String] {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("[") && trimmed.hasSuffix("]") else {
            return trimmed.isEmpty ? [] : [trimmed]
        }
        let innerContent = String(trimmed.dropFirst().dropLast())
        guard !innerContent.isEmpty else { return [] }
        return innerContent
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// Parses index.md content into structured WikiIndexEntry values.
    /// Expected format: `- [Title](path) — summary` grouped under `## Category` headers.
    private func parseIndexEntries(from indexContent: String) -> [WikiIndexEntry] {
        var entries: [WikiIndexEntry] = []
        var currentCategory = "uncategorized"
        let lines = indexContent.components(separatedBy: "\n")

        for line in lines {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)

            // Detect category headers
            if trimmedLine.hasPrefix("## ") {
                currentCategory = String(trimmedLine.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                continue
            }

            // Parse entry lines: - [Title](path) — summary
            guard trimmedLine.hasPrefix("- [") else { continue }
            guard let titleEndIndex = trimmedLine.range(of: "](") else { continue }
            guard let pathEndIndex = trimmedLine.range(of: ")") else { continue }

            let title = String(trimmedLine[trimmedLine.index(trimmedLine.startIndex, offsetBy: 3)..<titleEndIndex.lowerBound])
            let path = String(trimmedLine[titleEndIndex.upperBound..<pathEndIndex.lowerBound])

            var summary = ""
            if let dashSeparatorRange = trimmedLine.range(of: " — ", range: pathEndIndex.upperBound..<trimmedLine.endIndex) {
                summary = String(trimmedLine[dashSeparatorRange.upperBound...])
            }

            entries.append(WikiIndexEntry(
                pagePath: path,
                title: title,
                summary: summary,
                category: currentCategory
            ))
        }

        return entries
    }

    // MARK: - Default File Contents

    private static let defaultSchemaContent = """
    # ClaudeCursor Wiki Schema

    This wiki is maintained by ClaudeCursor's knowledge pipeline. The LLM reads
    from raw sources and writes structured wiki pages. Users can read and edit
    any file — manual edits are respected and never overwritten.

    ## Page Types

    - **entity**: A specific tool, app, or technology (e.g., "DaVinci Resolve", "VS Code")
    - **concept**: A technique, pattern, or idea (e.g., "color grading", "keyboard shortcuts")
    - **source-summary**: Summary of an ingested source document
    - **session**: Compressed observations from a user session

    ## Frontmatter Schema

    Every wiki page starts with YAML frontmatter:

    ```yaml
    ---
    type: entity | concept | source-summary | session
    title: Page Title
    sources: [source1.md, source2.md]
    date_created: 2026-04-19
    date_modified: 2026-04-19
    confidence: 0.8
    tags: [tag1, tag2]
    ---
    ```

    ## Conventions

    - One topic per page. Split broad topics into sub-pages.
    - Cross-reference related pages with markdown links: [Page Title](filename.md)
    - Keep summaries concise — detailed content goes in the body.
    - Confidence scores: 1.0 = verified from multiple sources, 0.5 = single source, 0.0 = speculative.
    - Sources array references files in raw/sources/ that informed this page.
    """

    private static let defaultIndexContent = """
    # ClaudeCursor Wiki Index

    This index catalogs all wiki pages. Updated automatically on every ingest.

    ## entities

    ## concepts

    ## source-summaries

    ## sessions
    """

    private static let defaultLogContent = """
    # ClaudeCursor Wiki Log

    Chronological record of wiki operations (ingests, queries, lint passes).
    """
}
