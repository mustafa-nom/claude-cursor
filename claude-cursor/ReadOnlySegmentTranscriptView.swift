//
//  ReadOnlySegmentTranscriptView.swift
//  claude-cursor
//
//  Renders a past chat session segment's turns as a read-only transcript.
//  Shown in the right-hand pane of the chat window when the sidebar
//  selection is `.segment(segmentID:)`. Reuses the existing
//  `ChatMessageBubble` from `ChatWindowController.swift` so styling stays
//  in lockstep with the live chat transcript.
//
//  Deliberately simple: no text input, no scroll-to-bottom on load (past
//  segments are meant to be browsed from the top), and a single "Back to
//  current chat" ghost button at the top so returning to the live view
//  is one click away.
//

import SwiftUI

struct ReadOnlySegmentTranscriptView: View {
    let segmentID: String
    let taskName: String
    let patternDatabase: PatternDatabase
    /// Called when the user taps "Back to current chat" — the parent
    /// (chat window root view) swaps the sidebar selection back to
    /// `.liveCurrent`. Passed in rather than mutating a binding so the
    /// root view keeps full control over selection state.
    let onRequestReturnToLiveChat: () -> Void

    @State private var turnsForSegment: [SegmentTurnRecord] = []
    @State private var isInitialLoadComplete: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()
                .background(DS.Colors.borderSubtle.opacity(0.5))

            transcriptBody
        }
        .background(DS.Colors.surface1)
        .onAppear(perform: loadTurnsForSegmentIfNeeded)
        .onChange(of: segmentID) { _ in
            isInitialLoadComplete = false
            loadTurnsForSegmentIfNeeded()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Button(action: onRequestReturnToLiveChat) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .medium))
                    Text("Back to current chat")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundColor(DS.Colors.textSecondary)
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

            Text(taskName)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.textTertiary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: - Transcript Body

    @ViewBuilder
    private var transcriptBody: some View {
        if !isInitialLoadComplete {
            loadingPlaceholder
        } else if turnsForSegment.isEmpty {
            emptyStatePlaceholder
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(turnsForSegment, id: \.turnIndex) { turn in
                        ChatMessageBubble(
                            role: .user,
                            text: turn.userText,
                            messageIndex: turn.turnIndex
                        )
                        ChatMessageBubble(
                            role: .assistant,
                            text: ClipboardManager.stripInternalCoordinationTags(
                                from: turn.assistantText
                            ),
                            messageIndex: turn.turnIndex
                        )
                    }
                }
                .padding(16)
            }
        }
    }

    private var loadingPlaceholder: some View {
        VStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("Loading transcript…")
                .font(.system(size: 12))
                .foregroundColor(DS.Colors.textTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyStatePlaceholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "text.bubble")
                .font(.system(size: 24))
                .foregroundColor(DS.Colors.textTertiary)
            Text("No turns were recorded for this segment.")
                .font(.system(size: 12))
                .foregroundColor(DS.Colors.textTertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Data Loading

    private func loadTurnsForSegmentIfNeeded() {
        let fetchedTurns = patternDatabase.listSegmentTurns(segmentID: segmentID)
        turnsForSegment = fetchedTurns
        isInitialLoadComplete = true
    }
}
