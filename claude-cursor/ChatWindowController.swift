//
//  ChatWindowController.swift
//  claude-cursor
//
//  Floating NSPanel that displays the conversation transcript and provides
//  a text input field for typed messages. Text messages go through the same
//  pipeline as voice (screenshot capture + wiki context + Claude API), so
//  the user gets identical behavior whether they type or talk.
//
//  Toggled by the "Show chat" toggle in the menu bar panel. Non-activating
//  so it doesn't steal focus from the user's current app.
//

import AppKit
import SwiftUI

/// Manages the floating chat transcript window lifecycle. Creates the
/// NSPanel on first show, reuses it on subsequent toggles.
@MainActor
final class ChatWindowController {

    private var chatPanel: NSPanel?
    /// AppKit does not retain `NSWindow.delegate`; keep the delegate alive
    /// so `windowWillClose` runs when the user closes the panel with the red X.
    private var chatPanelCloseDelegate: ChatPanelDelegate?
    private weak var companionManager: CompanionManager?
    /// Initial size when the panel is first created; user resize is preserved across hide/show.
    private let defaultPanelWidth: CGFloat = 360
    private let defaultPanelHeight: CGFloat = 520
    private let minimumPanelWidth: CGFloat = 328
    private let minimumPanelHeight: CGFloat = 440

    init(companionManager: CompanionManager) {
        self.companionManager = companionManager
    }

    /// Shows the chat panel. Creates it on first call, makes it visible on
    /// subsequent calls. Positioned in the bottom-right of the primary screen.
    func showChatPanel() {
        let didCreatePanel = (chatPanel == nil)
        if didCreatePanel {
            createChatPanel()
            positionNewPanelInBottomRightWithDefaultSize()
        }
        chatPanel?.makeKeyAndOrderFront(nil)
        chatPanel?.orderFrontRegardless()
    }

    /// Hides the chat panel without destroying it (quick re-show).
    func hideChatPanel() {
        chatPanel?.orderOut(nil)
    }

    /// Whether the chat panel is currently visible.
    var isPanelVisible: Bool {
        chatPanel?.isVisible ?? false
    }

    // MARK: - Private: Panel Creation

    private func createChatPanel() {
        guard let companionManager else { return }

        let chatView = ChatTranscriptView(companionManager: companionManager)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        let hostingView = NSHostingView(rootView: chatView)
        hostingView.autoresizingMask = [.width, .height]

        let panel = NSPanel(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: defaultPanelWidth,
                height: defaultPanelHeight
            ),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.title = "Claude Cursor Chat"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = NSColor(DS.Colors.surface1).withAlphaComponent(0.95)
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isExcludedFromWindowsMenu = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .visible
        panel.minSize = NSSize(width: minimumPanelWidth, height: minimumPanelHeight)
        panel.contentView = hostingView

        // When the user closes via the title bar X, toggle the setting off.
        // Retain the delegate on `self` (see `chatPanelCloseDelegate`); assigning
        // only to `panel.delegate` would let ARC release it immediately.
        let closeDelegate = ChatPanelDelegate(onClose: { [weak companionManager] in
            Task { @MainActor in
                companionManager?.setShowChatEnabled(false)
            }
        })
        chatPanelCloseDelegate = closeDelegate
        panel.delegate = closeDelegate

        chatPanel = panel
    }

    /// Places a newly created panel in the bottom-right of the primary screen
    /// using the default width and height. Does not run on subsequent
    /// `showChatPanel` calls so the user keeps their resized frame.
    private func positionNewPanelInBottomRightWithDefaultSize() {
        guard let panel = chatPanel,
              let screen = NSScreen.main else { return }

        let screenFrame = screen.visibleFrame
        let panelOriginX = screenFrame.maxX - defaultPanelWidth - 20
        let panelOriginY = screenFrame.minY + 20

        panel.setFrame(
            NSRect(
                x: panelOriginX,
                y: panelOriginY,
                width: defaultPanelWidth,
                height: defaultPanelHeight
            ),
            display: true
        )
    }
}

// MARK: - Panel Delegate

/// Receives close notifications from the chat panel's title bar X button
/// so the "Show chat" toggle stays in sync.
private class ChatPanelDelegate: NSObject, NSWindowDelegate {
    private let onClose: () -> Void

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }
}

// MARK: - Chat Transcript View

/// SwiftUI view for the chat transcript + text input field, hosted inside
/// the floating NSPanel.
struct ChatTranscriptView: View {
    @ObservedObject var companionManager: CompanionManager
    @State private var textInputContent: String = ""
    @State private var isTextInputFocused: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            // Scrollable transcript area
            ScrollViewReader { scrollProxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if companionManager.conversationHistory.isEmpty {
                            emptyStateView
                        } else {
                            ForEach(
                                Array(companionManager.conversationHistory.enumerated()),
                                id: \.offset
                            ) { index, entry in
                                ChatMessageBubble(
                                    role: .user,
                                    text: entry.userTranscript,
                                    messageIndex: index
                                )
                                ChatMessageBubble(
                                    role: .assistant,
                                    text: stripInternalTags(from: entry.assistantResponse),
                                    messageIndex: index
                                )
                            }
                        }
                    }
                    .padding(16)
                    .id("transcript-bottom")
                }
                .onChange(of: companionManager.conversationHistory.count) { _ in
                    withAnimation {
                        scrollProxy.scrollTo("transcript-bottom", anchor: .bottom)
                    }
                }
            }

            Divider()
                .background(DS.Colors.borderSubtle.opacity(0.5))

            // Text input area
            HStack(spacing: 8) {
                TextField("Type a message...", text: $textInputContent)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundColor(DS.Colors.textPrimary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: DS.CornerRadius.medium)
                            .fill(DS.Colors.surface2)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.CornerRadius.medium)
                            .stroke(DS.Colors.borderSubtle, lineWidth: 1)
                    )
                    .onSubmit {
                        sendTextMessage()
                    }

                Button(action: sendTextMessage) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 24))
                        .foregroundColor(
                            textInputContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                ? DS.Colors.textTertiary
                                : DS.Colors.accent
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .disabled(textInputContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(12)
        }
        .background(DS.Colors.surface1)
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        VStack(spacing: 8) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 28))
                .foregroundColor(DS.Colors.textTertiary)

            Text("No messages yet")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)

            Text("Type a message or use push-to-talk (Ctrl+Option)")
                .font(.system(size: 12))
                .foregroundColor(DS.Colors.textTertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, 60)
    }

    // MARK: - Actions

    private func sendTextMessage() {
        let trimmedMessage = textInputContent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedMessage.isEmpty else { return }
        textInputContent = ""
        companionManager.sendTextMessage(trimmedMessage)
    }

    /// Strips internal tags like [POINT:...] and [STEP:...] from the response
    /// text so the chat transcript shows clean, readable content. Delegates
    /// to ClipboardManager so the stripping rules match the clipboard path.
    private func stripInternalTags(from text: String) -> String {
        return ClipboardManager.stripInternalCoordinationTags(from: text)
    }
}

// MARK: - Chat Message Bubble

/// A single message bubble in the chat transcript, styled differently
/// for user messages (right-aligned, accent color) and assistant messages
/// (left-aligned, dark background).
struct ChatMessageBubble: View {
    enum MessageRole {
        case user
        case assistant
    }

    let role: MessageRole
    let text: String
    let messageIndex: Int

    var body: some View {
        Group {
            switch role {
            case .user:
                HStack(alignment: .top, spacing: 0) {
                    Spacer(minLength: 40)
                    bubbleCore
                }
            case .assistant:
                HStack(alignment: .top, spacing: 0) {
                    bubbleCore
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Spacer(minLength: 40)
                }
            }
        }
        .id("\(role)-\(messageIndex)")
    }

    private var bubbleCore: some View {
        Group {
            switch role {
            case .user:
                Text(text)
                    .font(.system(size: 13))
                    .foregroundColor(DS.Colors.textPrimary)
                    .textSelection(.enabled)
            case .assistant:
                assistantBubbleInner
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                .fill(bubbleBackgroundColor)
        )
        .clipShape(RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous))
    }

    @ViewBuilder
    private var assistantBubbleInner: some View {
        if RichMarkdownContent.containsLaTeXOrFencedCode(rawText: text) {
            ChatAssistantMathJaxBubble(markdownText: text)
        } else {
            Text(RichMarkdownContent.attributedStringFromMarkdownLossy(rawText: text))
                .font(.system(size: 13, weight: .regular))
                .foregroundColor(DS.Colors.textPrimary.opacity(0.92))
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
    }

    private var bubbleBackgroundColor: Color {
        switch role {
        case .user:
            return DS.Colors.accent.opacity(0.85)
        case .assistant:
            return DS.Colors.surface2
        }
    }
}

/// Sizes the MathJax web view to the rendered document height so the transcript
/// `ScrollView` scrolls as a whole instead of nesting a scroll area inside the bubble.
private struct ChatAssistantMathJaxBubble: View {
    let markdownText: String
    @State private var measuredContentHeight: CGFloat = 96

    var body: some View {
        MathJaxMarkdownWebView(
            responseText: markdownText,
            reportContentHeight: $measuredContentHeight
        )
        .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
        .frame(height: max(96, measuredContentHeight))
    }
}
