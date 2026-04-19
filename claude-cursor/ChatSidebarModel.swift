//
//  ChatSidebarModel.swift
//  claude-cursor
//
//  Observable model backing `ChatSidebarView`. Owns three things:
//    1. Segment data fetched from `PatternDatabase`, re-grouped into the
//       date-section → app-folder → (optional browser-tool subfolder) →
//       segment-row tree the sidebar renders.
//    2. Selection state — which segment (or "Current") is visible in the
//       right-hand detail pane.
//    3. Persisted expand/collapse state per folder key.
//
//  Refresh is driven by the `.chatSessionSegmentsDidChange` notification
//  posted by `ChatSessionSegmenter`. Search, when non-empty, bypasses the
//  date/app tree and renders a flat match list via
//  `PatternDatabase.searchChatSessionSegments`.
//

import Combine
import Foundation
import SwiftUI

// MARK: - Selection

/// Which detail view the right-hand pane should render. `liveCurrent`
/// shows the in-progress chat transcript; `segment(segmentID:)` shows a
/// past segment read-only.
enum ChatSidebarSelection: Equatable {
    case liveCurrent
    case segment(segmentID: String)
}

// MARK: - Sidebar Tree Models

/// One top-level date-bucket section in the sidebar (TODAY / YESTERDAY / …).
struct ChatSidebarDateSection: Identifiable {
    let id: String
    let displayLabel: String
    let appFoldersInOrder: [ChatSidebarAppFolder]
}

/// One app folder inside a date section. Native apps render
/// `.directSegments`; Chromium browsers render `.browserToolSubfolders` so
/// Linear / Figma / GitHub each get their own sub-entry under `Chrome`.
struct ChatSidebarAppFolder: Identifiable {
    let id: String
    let displayName: String
    let bundleIdentifier: String
    let leafContents: LeafContents

    enum LeafContents {
        case directSegments(segments: [ChatSidebarSegmentRow])
        case browserToolSubfolders(subfolders: [ChatSidebarBrowserToolSubfolder])
    }
}

/// A browser sub-folder keyed on `browserToolName` (e.g. "Linear").
struct ChatSidebarBrowserToolSubfolder: Identifiable {
    let id: String
    let toolDisplayName: String
    let browserHostname: String?
    let segmentsInOrder: [ChatSidebarSegmentRow]
}

/// A single selectable segment row in the sidebar.
struct ChatSidebarSegmentRow: Identifiable {
    let id: String
    let segmentID: String
    let displayTaskName: String
    let startedAtDate: Date
    let turnCount: Int
}

// MARK: - Model

@MainActor
final class ChatSidebarModel: ObservableObject {

    // MARK: Published State

    @Published private(set) var dateSectionsForSidebarTree: [ChatSidebarDateSection] = []
    @Published private(set) var flatSearchResults: [ChatSidebarSegmentRow] = []
    @Published var currentSelection: ChatSidebarSelection = .liveCurrent
    @Published var searchQueryText: String = "" {
        didSet { refreshSegmentsFromDatabase() }
    }

    /// Tracks expanded/collapsed state per folder key. Reads and writes
    /// go through UserDefaults so the tree remembers its shape across
    /// launches. Keyed by `folderKey(...)`.
    @Published private var expandedFolderKeys: Set<String> = []

    /// Count of session logs on disk that haven't been segmented yet —
    /// drives the "Older sessions — N not yet indexed" footer row. Nil
    /// while the initial count is pending.
    @Published private(set) var countOfUnbackfilledOlderSessions: Int = 0

    // MARK: Dependencies

    private let patternDatabase: PatternDatabase
    private let chatSessionBackfillRunner: ChatSessionBackfillRunner?

    /// How far back into the segments table the tree view pulls from. A
    /// wide default makes scrolling feel complete without needing a
    /// lazy "load more" paging step.
    private let sidebarFetchWindowInDays: Int = 60

    /// UserDefaults key prefix for expand/collapse state.
    private let folderExpandedUserDefaultsPrefix: String = "sidebar.expanded."

    /// Cap on search results so typing doesn't flood the UI.
    private let maximumFlatSearchResults: Int = 50

    private var notificationObserver: NSObjectProtocol?

    // MARK: Init

    init(
        patternDatabase: PatternDatabase,
        chatSessionBackfillRunner: ChatSessionBackfillRunner? = nil
    ) {
        self.patternDatabase = patternDatabase
        self.chatSessionBackfillRunner = chatSessionBackfillRunner

        loadPersistedExpandedFolderKeys()
        refreshSegmentsFromDatabase()

        // Subscribe to segmenter + backfill "did change" notifications so
        // the sidebar rebuilds whenever new segments land.
        notificationObserver = NotificationCenter.default.addObserver(
            forName: .chatSessionSegmentsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.refreshSegmentsFromDatabase()
            }
        }
    }

    deinit {
        if let notificationObserver {
            NotificationCenter.default.removeObserver(notificationObserver)
        }
    }

    // MARK: - Public API

    /// Triggers the backfill runner to process the next batch of
    /// un-indexed session logs. Called from the "Older sessions — N not
    /// yet indexed" footer row. The sidebar refreshes automatically once
    /// the segmenter posts its change notification.
    func requestBackfillOfAdditionalOlderSessions() async {
        guard let runner = chatSessionBackfillRunner else { return }
        await runner.backfillAdditionalUnprocessedSessions(
            maximumAdditionalFilesToProcess: 50
        )
        refreshUnbackfilledCountFromDisk()
    }

    /// Returns whether a folder key is currently expanded. Defaults to
    /// `true` so the tree feels open on first launch.
    func isFolderExpanded(folderKey: String) -> Bool {
        !expandedFolderKeys.contains(folderKey + ".collapsed")
    }

    /// Toggles a folder open/closed and persists the new state.
    func toggleFolderExpansion(folderKey: String) {
        let collapsedKey = folderKey + ".collapsed"
        if expandedFolderKeys.contains(collapsedKey) {
            expandedFolderKeys.remove(collapsedKey)
        } else {
            expandedFolderKeys.insert(collapsedKey)
        }
        UserDefaults.standard.set(
            expandedFolderKeys.contains(collapsedKey),
            forKey: folderExpandedUserDefaultsPrefix + folderKey
        )
    }

    /// Whether a search query is active. View-layer convenience.
    var isSearchActive: Bool {
        !searchQueryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Refresh Pipeline

    /// Rebuilds `dateSectionsForSidebarTree` OR `flatSearchResults`
    /// depending on whether a search query is active. Always runs on the
    /// main actor — called from init, notification, and didSet.
    func refreshSegmentsFromDatabase() {
        if isSearchActive {
            let trimmedQuery = searchQueryText.trimmingCharacters(in: .whitespacesAndNewlines)
            let matchingRecords = patternDatabase.searchChatSessionSegments(
                query: trimmedQuery,
                limit: maximumFlatSearchResults
            )
            .filter { Self.segmentRecordStartedToday(record: $0) }
            flatSearchResults = matchingRecords.map { Self.sidebarRow(fromRecord: $0) }
            dateSectionsForSidebarTree = []
        } else {
            let records = patternDatabase.listChatSessionSegments(
                sinceDaysAgo: sidebarFetchWindowInDays
            )
            .filter { Self.segmentRecordStartedToday(record: $0) }
            dateSectionsForSidebarTree = Self.buildDateSectionsTree(
                fromSegmentRecords: records
            )
            flatSearchResults = []
        }
        refreshUnbackfilledCountFromDisk()
    }

    private func refreshUnbackfilledCountFromDisk() {
        if let runner = chatSessionBackfillRunner {
            countOfUnbackfilledOlderSessions = runner.countOfUnbackfilledSessionLogFilesOnDisk()
        }
    }

    // MARK: - Tree Building

    /// Groups segments into date sections → app folders → (optional)
    /// browser-tool subfolders → segment rows. Pure so the logic is
    /// testable without a live database.
    static func buildDateSectionsTree(
        fromSegmentRecords records: [ChatSessionSegmentRecord]
    ) -> [ChatSidebarDateSection] {
        let calendar = Calendar.current
        let now = Date()

        // 1. Bucket every record by its date-section id + display label.
        var recordsByDateSectionID: [String: (label: String, sortOrder: Int, records: [ChatSessionSegmentRecord])] = [:]

        for record in records {
            guard let startedAtDate = Self.iso8601Date(fromString: record.startedAt) else {
                continue
            }
            let bucket = Self.dateSectionBucket(
                forDate: startedAtDate,
                relativeTo: now,
                calendar: calendar
            )
            var existingEntry = recordsByDateSectionID[bucket.id] ?? (label: bucket.label, sortOrder: bucket.sortOrder, records: [])
            existingEntry.records.append(record)
            recordsByDateSectionID[bucket.id] = existingEntry
        }

        // 2. For each bucket, build app folders + optional browser subfolders.
        let sortedSectionEntries = recordsByDateSectionID.sorted { lhs, rhs in
            lhs.value.sortOrder < rhs.value.sortOrder
        }

        return sortedSectionEntries.map { sectionID, bundle in
            ChatSidebarDateSection(
                id: sectionID,
                displayLabel: bundle.label,
                appFoldersInOrder: Self.buildAppFoldersForSection(
                    dateSectionID: sectionID,
                    records: bundle.records
                )
            )
        }
    }

    /// Session logs that predate bundle-ID capture leave `bundle_identifier`
    /// empty. Map common `app_name` values to stable bundle IDs so rows merge
    /// with newer segments and `CachedAppIconView` can resolve real icons.
    private static let bundleIdentifierForLegacyAppDisplayName: [String: String] = [
        "Google Chrome": "com.google.Chrome",
        "Safari": "com.apple.Safari",
        "Xcode": "com.apple.dt.Xcode",
        "Messages": "com.apple.MobileSMS",
    ]

    private static let sidebarFolderTitleForBundleIdentifier: [String: String] = [
        "com.google.Chrome": "Google Chrome",
        "com.apple.Safari": "Safari",
        "com.apple.dt.Xcode": "Xcode",
        "com.apple.MobileSMS": "Messages",
    ]

    private static func resolvedBundleIdentifierForSidebar(record: ChatSessionSegmentRecord) -> String {
        if !record.bundleIdentifier.isEmpty {
            return record.bundleIdentifier
        }
        return bundleIdentifierForLegacyAppDisplayName[record.appName] ?? ""
    }

    private static func canonicalAppGroupingKey(for record: ChatSessionSegmentRecord) -> String {
        let resolved = resolvedBundleIdentifierForSidebar(record: record)
        if !resolved.isEmpty {
            return "bundleid:\(resolved)"
        }
        return "appname:\(record.appName)"
    }

    private static func mergedResolvedBundleIdentifier(from records: [ChatSessionSegmentRecord]) -> String {
        for record in records {
            let bundleID = resolvedBundleIdentifierForSidebar(record: record)
            if !bundleID.isEmpty { return bundleID }
        }
        return ""
    }

    private static func sidebarFolderDisplayName(
        for records: [ChatSessionSegmentRecord],
        resolvedBundleID: String
    ) -> String {
        if !resolvedBundleID.isEmpty,
           let title = sidebarFolderTitleForBundleIdentifier[resolvedBundleID] {
            return title
        }
        if let firstNonEmptyName = records.first(where: { !$0.appName.isEmpty })?.appName {
            return firstNonEmptyName
        }
        return "Unknown"
    }

    private static func buildAppFoldersForSection(
        dateSectionID: String,
        records: [ChatSessionSegmentRecord]
    ) -> [ChatSidebarAppFolder] {
        var recordsByAppKey: [String: (appName: String, bundleID: String, records: [ChatSessionSegmentRecord])] = [:]
        for record in records {
            let appKey = canonicalAppGroupingKey(for: record)
            var entry = recordsByAppKey[appKey] ?? (appName: record.appName, bundleID: "", records: [])
            entry.records.append(record)
            let resolved = resolvedBundleIdentifierForSidebar(record: record)
            if entry.bundleID.isEmpty, !resolved.isEmpty {
                entry.bundleID = resolved
            }
            recordsByAppKey[appKey] = entry
        }

        // Sort app folders by latest activity first. `startedAt` is an
        // ISO string so string comparison matches chronological order.
        let sortedAppEntries = recordsByAppKey.sorted { lhs, rhs in
            let lhsLatest = lhs.value.records.map(\.startedAt).max() ?? ""
            let rhsLatest = rhs.value.records.map(\.startedAt).max() ?? ""
            return lhsLatest > rhsLatest
        }

        return sortedAppEntries.map { appKey, appEntry in
            let iconBundleID = mergedResolvedBundleIdentifier(from: appEntry.records)
            let displayName = sidebarFolderDisplayName(for: appEntry.records, resolvedBundleID: iconBundleID)
            return ChatSidebarAppFolder(
                id: "\(dateSectionID)|\(appKey)",
                displayName: displayName,
                bundleIdentifier: iconBundleID,
                leafContents: buildLeafContentsForAppFolder(
                    appFolderID: "\(dateSectionID)|\(appKey)",
                    records: appEntry.records
                )
            )
        }
    }

    private static func buildLeafContentsForAppFolder(
        appFolderID: String,
        records: [ChatSessionSegmentRecord]
    ) -> ChatSidebarAppFolder.LeafContents {
        let recordsWithBrowserTool = records.filter {
            ($0.browserToolName ?? "").isEmpty == false
        }

        // If no record in this app folder has a browser tool name, render
        // flat segment rows — this is the native-app path.
        if recordsWithBrowserTool.isEmpty {
            let segmentRows = records
                .sorted { $0.startedAt > $1.startedAt }
                .map { sidebarRow(fromRecord: $0) }
            return .directSegments(segments: segmentRows)
        }

        // Otherwise bucket by browser tool name. Records with no tool name
        // (rare — user visited a browser page without a matched tool)
        // land under an "Other" catch-all so they don't vanish.
        var recordsByToolName: [String: (hostname: String?, records: [ChatSessionSegmentRecord])] = [:]
        for record in records {
            let toolKey = record.browserToolName ?? "Other"
            var entry = recordsByToolName[toolKey] ?? (hostname: record.browserHostname, records: [])
            entry.records.append(record)
            // First-seen hostname wins — arbitrary but stable.
            if entry.hostname == nil { entry.hostname = record.browserHostname }
            recordsByToolName[toolKey] = entry
        }

        let sortedSubfolders = recordsByToolName.sorted { lhs, rhs in
            let lhsLatest = lhs.value.records.map(\.startedAt).max() ?? ""
            let rhsLatest = rhs.value.records.map(\.startedAt).max() ?? ""
            return lhsLatest > rhsLatest
        }

        let subfolderList = sortedSubfolders.map { toolName, entry in
            ChatSidebarBrowserToolSubfolder(
                id: "\(appFolderID)|tool:\(toolName)",
                toolDisplayName: toolName,
                browserHostname: entry.hostname,
                segmentsInOrder: entry.records
                    .sorted { $0.startedAt > $1.startedAt }
                    .map { sidebarRow(fromRecord: $0) }
            )
        }

        return .browserToolSubfolders(subfolders: subfolderList)
    }

    private static func sidebarRow(fromRecord record: ChatSessionSegmentRecord) -> ChatSidebarSegmentRow {
        ChatSidebarSegmentRow(
            id: record.segmentID,
            segmentID: record.segmentID,
            displayTaskName: record.taskName.isEmpty ? "Untitled" : record.taskName,
            startedAtDate: iso8601Date(fromString: record.startedAt) ?? Date(),
            turnCount: record.turnCount
        )
    }

    // MARK: - Date Bucketing

    /// Maps a segment's started-at date to the sidebar's date bucket. The
    /// `sortOrder` field lets the caller sort sections in descending
    /// recency without repeating the if/else ladder.
    private static func dateSectionBucket(
        forDate date: Date,
        relativeTo reference: Date,
        calendar: Calendar
    ) -> (id: String, label: String, sortOrder: Int) {
        if calendar.isDateInToday(date) {
            return (id: "today", label: "TODAY", sortOrder: 0)
        }
        if calendar.isDateInYesterday(date) {
            return (id: "yesterday", label: "YESTERDAY", sortOrder: 1)
        }

        let referenceWeek = calendar.component(.weekOfYear, from: reference)
        let referenceYear = calendar.component(.yearForWeekOfYear, from: reference)
        let dateWeek = calendar.component(.weekOfYear, from: date)
        let dateYear = calendar.component(.yearForWeekOfYear, from: date)

        if referenceYear == dateYear && referenceWeek == dateWeek {
            return (id: "this-week", label: "THIS WEEK", sortOrder: 2)
        }
        // Handle year-wrap: last week of prior year is "LAST WEEK" too.
        let dateIsInLastCalendarWeek: Bool = {
            guard let referenceStart = calendar.date(
                from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: reference)
            ), let oneWeekEarlierStart = calendar.date(
                byAdding: .weekOfYear, value: -1, to: referenceStart
            ) else {
                return false
            }
            let lastWeekYear = calendar.component(.yearForWeekOfYear, from: oneWeekEarlierStart)
            let lastWeekWeek = calendar.component(.weekOfYear, from: oneWeekEarlierStart)
            return dateYear == lastWeekYear && dateWeek == lastWeekWeek
        }()

        if dateIsInLastCalendarWeek {
            return (id: "last-week", label: "LAST WEEK", sortOrder: 3)
        }

        // Older months bucketed by month label ("FEBRUARY 2026").
        let monthLabelFormatter = DateFormatter()
        monthLabelFormatter.dateFormat = "MMMM yyyy"
        let monthLabel = monthLabelFormatter.string(from: date).uppercased()
        // Sort order: newer months first. Use a negative "month-since-epoch"
        // so more recent dates have lower sortOrder values.
        let monthsSinceReferenceEpoch = monthsSinceReferenceZero(date: date, calendar: calendar)
        let sortOrder = 10_000 - monthsSinceReferenceEpoch

        let yearMonthID = {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM"
            return "month-\(f.string(from: date))"
        }()

        return (id: yearMonthID, label: monthLabel, sortOrder: sortOrder)
    }

    /// Arbitrary but monotonic mapping from a date to an integer month
    /// index — lets `dateSectionBucket` compute sortOrder by subtraction.
    private static func monthsSinceReferenceZero(date: Date, calendar: Calendar) -> Int {
        let components = calendar.dateComponents([.year, .month], from: date)
        let year = components.year ?? 2000
        let month = components.month ?? 1
        return year * 12 + month
    }

    // MARK: - UserDefaults Persistence

    private func loadPersistedExpandedFolderKeys() {
        // We store ONLY the collapsed markers: default state is expanded.
        // Iterate once over the defaults dictionary so startup doesn't
        // require reading every possible key.
        let allDefaults = UserDefaults.standard.dictionaryRepresentation()
        for (key, value) in allDefaults where key.hasPrefix(folderExpandedUserDefaultsPrefix) {
            guard let markedAsCollapsed = value as? Bool, markedAsCollapsed else { continue }
            let folderKey = String(key.dropFirst(folderExpandedUserDefaultsPrefix.count))
            expandedFolderKeys.insert(folderKey + ".collapsed")
        }
    }

    /// The chat sidebar intentionally hides anything before the current local
    /// calendar day so only "today" sessions appear (no yesterday / last week
    /// buckets).
    private static func segmentRecordStartedToday(record: ChatSessionSegmentRecord) -> Bool {
        guard let startedAtDate = iso8601Date(fromString: record.startedAt) else { return false }
        return Calendar.current.isDateInToday(startedAtDate)
    }

    private static func iso8601Date(fromString iso: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: iso)
    }
}
