//
//  AnswerPanelView.swift
//  claude-cursor
//
//  Floating answer panel that displays detailed, markdown-rendered responses
//  for questions that need a fuller treatment than the cursor-follow overlay
//  can reasonably show. Used when the AdaptiveOutputRouter decides the
//  response is "Answer" mode (explanation, breakdown, tutorial content) rather
//  than "Navigation" (a single pointing gesture) or "Chat" (a short reply).
//
//  Panel behavior:
//    - Non-activating floating NSPanel so it overlays above all apps without
//      stealing focus from the user's current task.
//    - Sized ~400x360, positioned top-right of the primary screen with a 20px
//      margin, matching the general floating-window aesthetic of the app.
//
//  Persistence rules (owned by CompanionManager, not the controller):
//    1. Auto-dismiss at the start of every new voice/chat interaction so
//       stale content doesn't linger while the user asks something new.
//       If the router picks `.answer` again, the panel is reopened with the
//       fresh response.
//    2. The close button in the panel header hides the panel explicitly;
//       the underlying NSPanel is retained so the next show reuses it.
//    3. The panel does NOT auto-dismiss on outside click — unlike the menu
//       bar dropdown, the answer panel is intended to be read at the user's
//       own pace while they continue working in other apps.
//    4. The panel is hidden if the companion transitions into a mode that
//       owns the screen exclusively (e.g. lesson mode). This prevents
//       overlap with the lesson step overlay.
//

import AppKit
import Combine
import SwiftUI

// MARK: - Answer Panel Controller

/// Manages the lifecycle of the floating answer panel. Creates the NSPanel
/// on first show, reuses it on subsequent shows so the content view state
/// (scroll position, selected text) is preserved while the panel is hidden.
@MainActor
final class AnswerPanelController {

    private var answerPanel: NSPanel?
    private let answerPanelViewModel = AnswerPanelViewModel()
    private weak var companionManager: CompanionManager?

    /// Width of the floating answer panel, in points.
    private let answerPanelWidth: CGFloat = 420

    /// Height of the floating answer panel, in points.
    private let answerPanelHeight: CGFloat = 360

    /// Margin from the edge of the screen when positioning the panel.
    private let screenEdgeMargin: CGFloat = 20

    /// Markdown last written to the panel during the current assistant turn
    /// (`open_answer_panel` or router `.answer`). Cleared by
    /// `resetMarkdownTrackingForNewTurn()` so chat history can mirror the
    /// panel even when streamed `fullResponseText` omits tool payloads.
    private(set) var markdownLastPresentedThisTurn: String?

    init(companionManager: CompanionManager) {
        self.companionManager = companionManager
    }

    // MARK: - Public API

    /// Clears per-turn panel markdown tracking. Call when starting a new
    /// vision/tool turn alongside `CompanionToolRegistry.beginTurn`.
    func resetMarkdownTrackingForNewTurn() {
        markdownLastPresentedThisTurn = nil
    }

    /// Shows the answer panel with the given response text. Creates the panel
    /// on first call, reuses it on subsequent calls. The panel renders the
    /// text as markdown so headings, lists, and emphasis display correctly.
    func showAnswerPanel(withResponseText responseText: String) {
        let cleanedResponseText = ClipboardManager.stripInternalCoordinationTags(
            from: responseText
        )
        markdownLastPresentedThisTurn = cleanedResponseText
        answerPanelViewModel.responseText = cleanedResponseText

        if answerPanel == nil {
            createAnswerPanel()
        }

        positionPanelInTopRight()
        answerPanel?.orderFrontRegardless()
    }

    /// Hides the answer panel without destroying it, so content state survives
    /// across hide/show cycles (user scroll position, selected text).
    func hideAnswerPanel() {
        answerPanel?.orderOut(nil)
    }

    /// Whether the answer panel is currently visible on screen.
    var isAnswerPanelVisible: Bool {
        answerPanel?.isVisible ?? false
    }

    // MARK: - Private: Panel Creation

    private func createAnswerPanel() {
        let answerView = AnswerPanelView(
            viewModel: answerPanelViewModel,
            onCloseButtonTapped: { [weak self] in
                self?.hideAnswerPanel()
            }
        )
        .frame(width: answerPanelWidth, height: answerPanelHeight)

        let hostingView = NSHostingView(rootView: answerView)
        hostingView.frame = NSRect(
            x: 0,
            y: 0,
            width: answerPanelWidth,
            height: answerPanelHeight
        )

        let panel = NSPanel(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: answerPanelWidth,
                height: answerPanelHeight
            ),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        // Floating, non-activating: overlays other apps without stealing focus.
        // This is critical — the user must be able to keep typing/clicking in
        // their current app while reading the answer.
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isExcludedFromWindowsMenu = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.contentView = hostingView

        answerPanel = panel
    }

    private func positionPanelInTopRight() {
        guard let panel = answerPanel,
              let primaryScreen = NSScreen.main else { return }

        let screenVisibleFrame = primaryScreen.visibleFrame
        let panelOriginX = screenVisibleFrame.maxX - answerPanelWidth - screenEdgeMargin
        let panelOriginY = screenVisibleFrame.maxY - answerPanelHeight - screenEdgeMargin

        panel.setFrame(
            NSRect(
                x: panelOriginX,
                y: panelOriginY,
                width: answerPanelWidth,
                height: answerPanelHeight
            ),
            display: true
        )
    }

}

// MARK: - View Model

/// Observable state for the answer panel. Kept as a view model (not @State
/// inside the view) so the controller can push new content without rebuilding
/// the hosting view.
@MainActor
final class AnswerPanelViewModel: ObservableObject {
    @Published var responseText: String = ""
}

// MARK: - Answer Panel SwiftUI View

/// SwiftUI view for the floating answer panel. Renders the response text as
/// markdown using `AttributedString` so headings, lists, bold/italic, and
/// inline code display with proper styling. Scrollable when content exceeds
/// the panel height.
struct AnswerPanelView: View {
    @ObservedObject var viewModel: AnswerPanelViewModel
    let onCloseButtonTapped: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            panelHeaderRow
            Divider()
                .background(DS.Colors.borderSubtle.opacity(0.5))
            scrollableResponseContent
        }
        .background(
            RoundedRectangle(
                cornerRadius: DS.CornerRadius.extraLarge,
                style: .continuous
            )
            .fill(DS.Colors.surface1.opacity(0.98))
        )
        .overlay(
            RoundedRectangle(
                cornerRadius: DS.CornerRadius.extraLarge,
                style: .continuous
            )
            .stroke(DS.Colors.borderSubtle.opacity(0.6), lineWidth: 0.8)
        )
        .shadow(color: Color.black.opacity(0.45), radius: 24, x: 0, y: 10)
    }

    // MARK: - Header

    private var panelHeaderRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(DS.Colors.accentText)

            Text("Answer")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)

            Spacer()

            Button(action: onCloseButtonTapped) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(DS.Colors.textSecondary)
                    .frame(width: 20, height: 20)
                    .background(
                        Circle()
                            .fill(DS.Colors.surface3.opacity(0.6))
                    )
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .help("Close")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Scrollable Content

    /// Chooses the rich content renderer. When the response includes LaTeX
    /// markers or fenced code blocks, we render via WKWebView with MathJax
    /// and marked.js. For plain
    /// markdown without math or fenced code, the native AttributedString
    /// path is kept — faster render, no web view spin-up cost.
    private var scrollableResponseContent: some View {
        Group {
            if RichMarkdownContent.containsLaTeXOrFencedCode(rawText: viewModel.responseText) {
                MathJaxMarkdownWebView(responseText: viewModel.responseText)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 8)
            } else {
                ScrollView(.vertical, showsIndicators: true) {
                    Text(RichMarkdownContent.attributedStringFromMarkdownLossy(rawText: viewModel.responseText))
                        .font(.system(size: 13, weight: .regular))
                        .foregroundColor(DS.Colors.textPrimary)
                        .lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                }
            }
        }
    }
}
