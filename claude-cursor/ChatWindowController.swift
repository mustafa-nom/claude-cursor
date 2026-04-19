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
    private weak var companionManager: CompanionManager?
    private let panelWidth: CGFloat = 360
    private let panelHeight: CGFloat = 520

    init(companionManager: CompanionManager) {
        self.companionManager = companionManager
    }

    /// Shows the chat panel. Creates it on first call, makes it visible on
    /// subsequent calls. Positioned in the bottom-right of the primary screen.
    func showChatPanel() {
        if chatPanel == nil {
            createChatPanel()
        }
        positionPanelInBottomRight()
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
            .frame(width: panelWidth, height: panelHeight)

        let hostingView = NSHostingView(rootView: chatView)
        hostingView.frame = NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight)

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight),
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
        panel.minSize = NSSize(width: 300, height: 400)
        panel.contentView = hostingView

        // When the user closes via the title bar X, toggle the setting off.
        // Dispatch async so the @Published update lands on a clean runloop tick
        // after the NSWindow teardown completes — otherwise SwiftUI's observed
        // refresh can race with the window close and the menu bar Toggle stays
        // visually "on" even though the underlying state is false.
        panel.delegate = ChatPanelDelegate(onClose: { [weak companionManager] in
            DispatchQueue.main.async {
                companionManager?.setShowChatEnabled(false)
            }
        })

        chatPanel = panel
    }

    private func positionPanelInBottomRight() {
        guard let panel = chatPanel,
              let screen = NSScreen.main else { return }

        let screenFrame = screen.visibleFrame
        let panelOriginX = screenFrame.maxX - panelWidth - 20
        let panelOriginY = screenFrame.minY + 20

        panel.setFrame(
            NSRect(x: panelOriginX, y: panelOriginY, width: panelWidth, height: panelHeight),
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
        HStack {
            if role == .user { Spacer(minLength: 40) }

            Text(text)
                .font(.system(size: 13))
                .foregroundColor(role == .user ? DS.Colors.textPrimary : DS.Colors.textPrimary.opacity(0.92))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.large)
                        .fill(bubbleBackgroundColor)
                )
                .textSelection(.enabled)

            if role == .assistant { Spacer(minLength: 40) }
        }
        .id("\(role)-\(messageIndex)")
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
