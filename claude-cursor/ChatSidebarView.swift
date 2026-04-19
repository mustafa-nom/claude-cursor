//
//  ChatSidebarView.swift
//  claude-cursor
//
//  Granola-style left sidebar for the chat window. Top-level structure:
//
//      ┌────────────────────┐
//      │ + New Chat     🔍  │  header
//      │ 🔎 Search…         │  optional
//      │ ● Current          │  pinned
//      │ TODAY              │  date section label
//      │ ▾ VS Code          │  app folder (collapsible)
//      │    • auth-refactor │  segment row
//      │ ▾ Chrome           │
//      │    ▾ Linear        │  browser-tool sub-folder
//      │       • ticket-123 │
//      └────────────────────┘
//
//  All state lives in `ChatSidebarModel`. This view is a thin renderer.
//  "Shadcn-inspired" in the design system sense — system font, generous
//  whitespace, muted neutrals, minimal chrome — implemented against the
//  existing `DS.Colors` tokens (shadcn itself is React/Tailwind and can't
//  be imported into SwiftUI).
//

import SwiftUI

struct ChatSidebarView: View {

    @ObservedObject var sidebarModel: ChatSidebarModel

    /// Triggered by the "+ New Chat" button. The chat window root view
    /// is responsible for calling `CompanionManager.endCurrentChatSessionExplicitly`
    /// and swapping the selection back to `.liveCurrent`.
    let onNewChatRequested: () -> Void

    @State private var isSearchFieldExpanded: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            headerBar

            Divider()
                .background(DS.Colors.borderSubtle.opacity(0.4))

            if isSearchFieldExpanded || sidebarModel.isSearchActive {
                searchField
                Divider()
                    .background(DS.Colors.borderSubtle.opacity(0.4))
            }

            scrollableBody
        }
        .frame(width: 220)
        .background(DS.Colors.sidebarBackground)
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 6) {
            Button(action: onNewChatRequested) {
                HStack(spacing: 4) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                    Text("New Chat")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundColor(DS.Colors.textPrimary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.small)
                        .fill(DS.Colors.surface2.opacity(0.7))
                )
            }
            .buttonStyle(.plain)
            .pointerCursor()

            Spacer(minLength: 0)

            Button(action: { isSearchFieldExpanded.toggle() }) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
                    .padding(6)
            }
            .buttonStyle(.plain)
            .pointerCursor()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    // MARK: - Search Field

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)

            TextField("Search past chats…", text: $sidebarModel.searchQueryText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundColor(DS.Colors.textPrimary)

            if !sidebarModel.searchQueryText.isEmpty {
                Button(action: { sidebarModel.searchQueryText = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.textTertiary)
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    // MARK: - Scrollable Body

    private var scrollableBody: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                pinnedCurrentRow
                    .padding(.top, 6)
                    .padding(.horizontal, 6)

                if sidebarModel.isSearchActive {
                    flatSearchResultsList
                        .padding(.horizontal, 6)
                        .padding(.top, 8)
                } else {
                    dateSectionsTreeList
                        .padding(.horizontal, 6)
                        .padding(.top, 6)

                    if sidebarModel.countOfUnbackfilledOlderSessions > 0 {
                        olderSessionsFooterRow
                            .padding(.horizontal, 6)
                            .padding(.vertical, 10)
                    }
                }
            }
            .padding(.bottom, 12)
        }
    }

    // MARK: - Pinned Current Row

    private var pinnedCurrentRow: some View {
        Button(action: { sidebarModel.currentSelection = .liveCurrent }) {
            HStack(spacing: 8) {
                Circle()
                    .fill(DS.Colors.accent)
                    .frame(width: 6, height: 6)
                Text("Current")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textPrimary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, DS.Spacing.sidebarRowVertical)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.small)
                    .fill(
                        sidebarModel.currentSelection == .liveCurrent
                            ? DS.Colors.sidebarRowSelected
                            : Color.clear
                    )
            )
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    // MARK: - Tree List

    @ViewBuilder
    private var dateSectionsTreeList: some View {
        if sidebarModel.dateSectionsForSidebarTree.isEmpty {
            emptyStateNoSegmentsYet
        } else {
            ForEach(sidebarModel.dateSectionsForSidebarTree) { section in
                dateSectionView(section: section)
            }
        }
    }

    private func dateSectionView(section: ChatSidebarDateSection) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(section.displayLabel)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(DS.Colors.sidebarSectionLabel)
                .padding(.top, 12)
                .padding(.bottom, 4)
                .padding(.horizontal, 10)

            ForEach(section.appFoldersInOrder) { appFolder in
                appFolderView(appFolder: appFolder)
            }
        }
    }

    @ViewBuilder
    private func appFolderView(appFolder: ChatSidebarAppFolder) -> some View {
        let isExpanded = sidebarModel.isFolderExpanded(folderKey: appFolder.id)

        VStack(alignment: .leading, spacing: 0) {
            Button(action: {
                sidebarModel.toggleFolderExpansion(folderKey: appFolder.id)
            }) {
                HStack(spacing: 6) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(DS.Colors.sidebarCaret)
                        .frame(width: 10)

                    CachedAppIconView(
                        bundleIdentifier: appFolder.bundleIdentifier,
                        pointSize: 14
                    )

                    Text(appFolder.displayName)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(DS.Colors.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, DS.Spacing.sidebarRowVertical)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerCursor()

            if isExpanded {
                folderLeafContents(
                    leafContents: appFolder.leafContents,
                    indentLevel: 1
                )
            }
        }
    }

    @ViewBuilder
    private func folderLeafContents(
        leafContents: ChatSidebarAppFolder.LeafContents,
        indentLevel: Int
    ) -> some View {
        switch leafContents {
        case .directSegments(let segments):
            ForEach(segments) { segmentRow in
                sidebarSegmentRowView(
                    segmentRow: segmentRow,
                    indentLevel: indentLevel
                )
            }
        case .browserToolSubfolders(let subfolders):
            ForEach(subfolders) { subfolder in
                browserToolSubfolderView(
                    subfolder: subfolder,
                    indentLevel: indentLevel
                )
            }
        }
    }

    @ViewBuilder
    private func browserToolSubfolderView(
        subfolder: ChatSidebarBrowserToolSubfolder,
        indentLevel: Int
    ) -> some View {
        let isExpanded = sidebarModel.isFolderExpanded(folderKey: subfolder.id)
        let indentAmount = CGFloat(indentLevel) * DS.Spacing.sidebarRowIndentPerLevel

        VStack(alignment: .leading, spacing: 0) {
            Button(action: {
                sidebarModel.toggleFolderExpansion(folderKey: subfolder.id)
            }) {
                HStack(spacing: 6) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(DS.Colors.sidebarCaret)
                        .frame(width: 10)

                    browserToolAvatar(toolName: subfolder.toolDisplayName)

                    Text(subfolder.toolDisplayName)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(DS.Colors.textPrimary)
                        .lineLimit(1)

                    Spacer(minLength: 0)
                }
                .padding(.leading, 8 + indentAmount)
                .padding(.trailing, 8)
                .padding(.vertical, DS.Spacing.sidebarRowVertical)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerCursor()

            if isExpanded {
                ForEach(subfolder.segmentsInOrder) { segmentRow in
                    sidebarSegmentRowView(
                        segmentRow: segmentRow,
                        indentLevel: indentLevel + 1
                    )
                }
            }
        }
    }

    private func browserToolAvatar(toolName: String) -> some View {
        let initials = Self.initialsFromDisplayName(toolName)
        let tint = Self.tintColorForDisplayName(toolName)

        return Text(initials)
            .font(.system(size: 8, weight: .bold))
            .foregroundColor(.white)
            .frame(width: 14, height: 14)
            .background(Circle().fill(tint))
    }

    @ViewBuilder
    private func sidebarSegmentRowView(
        segmentRow: ChatSidebarSegmentRow,
        indentLevel: Int
    ) -> some View {
        let indentAmount = CGFloat(indentLevel) * DS.Spacing.sidebarRowIndentPerLevel
        let isSelected = sidebarModel.currentSelection == .segment(segmentID: segmentRow.segmentID)

        Button(action: {
            sidebarModel.currentSelection = .segment(segmentID: segmentRow.segmentID)
        }) {
            HStack(spacing: 6) {
                Text(segmentRow.displayTaskName)
                    .font(.system(size: 12))
                    .foregroundColor(DS.Colors.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 4)

                Text(Self.relativeTimeLabel(forDate: segmentRow.startedAtDate))
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.textTertiary)
            }
            .padding(.leading, 8 + indentAmount)
            .padding(.trailing, 8)
            .padding(.vertical, DS.Spacing.sidebarRowVertical)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.small)
                    .fill(isSelected ? DS.Colors.sidebarRowSelected : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    // MARK: - Flat Search Results

    @ViewBuilder
    private var flatSearchResultsList: some View {
        if sidebarModel.flatSearchResults.isEmpty {
            Text("No matches")
                .font(.system(size: 12))
                .foregroundColor(DS.Colors.textTertiary)
                .padding(.horizontal, 10)
                .padding(.vertical, 16)
        } else {
            ForEach(sidebarModel.flatSearchResults) { segmentRow in
                sidebarSegmentRowView(segmentRow: segmentRow, indentLevel: 0)
            }
        }
    }

    // MARK: - Footer Rows

    private var olderSessionsFooterRow: some View {
        Button(action: {
            Task { await sidebarModel.requestBackfillOfAdditionalOlderSessions() }
        }) {
            HStack(spacing: 6) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
                Text("Older sessions — \(sidebarModel.countOfUnbackfilledOlderSessions) not yet indexed")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
                    .lineLimit(2)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    private var emptyStateNoSegmentsYet: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("No past chats yet")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)
            Text("Click + New Chat to end the current session and file it here.")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 14)
    }

    // MARK: - Helpers

    /// Condensed relative-time label for the right edge of segment rows.
    /// E.g. "2m", "3h", "Yesterday", "Mar 4". Keeps the sidebar scannable
    /// at the expense of precision — the read-only segment view shows
    /// full timestamps.
    private static func relativeTimeLabel(forDate date: Date) -> String {
        let secondsSince = Date().timeIntervalSince(date)
        let calendar = Calendar.current

        if secondsSince < 60 {
            return "now"
        }
        if secondsSince < 3600 {
            return "\(Int(secondsSince / 60))m"
        }
        if calendar.isDateInToday(date) {
            return "\(Int(secondsSince / 3600))h"
        }
        if calendar.isDateInYesterday(date) {
            return "Yest"
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter.string(from: date)
    }

    private static func initialsFromDisplayName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return "?" }
        let words = trimmed.split(separator: " ")
        if words.count >= 2 {
            return String(words[0].prefix(1) + words[1].prefix(1)).uppercased()
        }
        return String(trimmed.prefix(2)).uppercased()
    }

    /// Hashes a string to a stable-but-arbitrary palette index. Gives
    /// every tool a predictable tint color across launches without
    /// needing a lookup table.
    private static func tintColorForDisplayName(_ name: String) -> Color {
        let palette: [Color] = [
            Color(hex: "#D97757"),
            Color(hex: "#6B8E23"),
            Color(hex: "#5B8DEF"),
            Color(hex: "#C084FC"),
            Color(hex: "#14B8A6"),
            Color(hex: "#F59E0B"),
            Color(hex: "#EC4899")
        ]
        let hashValue = name.unicodeScalars.reduce(0) { acc, scalar in
            (acc &* 31) &+ Int(scalar.value)
        }
        let index = abs(hashValue) % palette.count
        return palette[index]
    }
}
