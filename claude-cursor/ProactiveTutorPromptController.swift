//
//  ProactiveTutorPromptController.swift
//  claude-cursor
//
//  Floating speech-bubble prompt that asks the user a proactive yes/no
//  question during tutor mode — e.g. "Want me to walk you through the
//  basics?" — with inline approve/deny buttons. Rendered in a dedicated
//  mouse-accepting NSPanel positioned near the cursor so the user can tap
//  without leaving their current app.
//
//  Unlike the cursor overlay (which is pass-through for mouse events so
//  users can interact with whatever's underneath it), this panel accepts
//  mouse events so the yes/no buttons are clickable. It does not steal
//  focus — clicking a button dispatches the decision callback and hides
//  the panel without activating the ClaudeCursor app.
//

import AppKit
import Combine
import SwiftUI

// MARK: - Prompt Response

/// The user's response to a proactive tutor prompt. Recorded to the
/// PatternDatabase for rate-limiting purposes (backoff after consecutive
/// rejections).
enum ProactiveTutorPromptResponse {
    case accepted
    case rejected
}

// MARK: - Controller

/// Manages the lifecycle of the proactive tutor prompt panel. Creates the
/// NSPanel on first show, reuses it thereafter so successive prompts feel
/// snappy. The panel is positioned near the current mouse location but
/// clamped to the visible screen so it never appears off-edge.
@MainActor
final class ProactiveTutorPromptController {

    private var promptPanel: NSPanel?
    private let promptViewModel = ProactiveTutorPromptViewModel()

    /// Maximum width of the prompt bubble, in points.
    private let promptPanelMaxWidth: CGFloat = 320

    /// Horizontal and vertical offset from the cursor when positioning the
    /// panel — keeps the bubble from overlapping the cursor itself.
    private let cursorOffsetHorizontal: CGFloat = 24
    private let cursorOffsetVertical: CGFloat = 12

    /// Completion handler invoked when the user taps Yes or No. Cleared
    /// after the first tap so accidental double-dispatch can't happen.
    private var responseCompletionHandler: ((ProactiveTutorPromptResponse) -> Void)?

    // MARK: - Public API

    /// Shows the prompt with the given message, positioning it near the
    /// current mouse cursor. Calls `responseHandler` exactly once when the
    /// user taps Yes or No. If the prompt is dismissed programmatically
    /// (e.g. the tutor mode is turned off) without a user tap, the handler
    /// is NOT called — callers should treat that as the default "no action"
    /// and not record a nudge event.
    func showPrompt(
        withMessage promptMessage: String,
        onResponse responseHandler: @escaping (ProactiveTutorPromptResponse) -> Void
    ) {
        promptViewModel.promptMessageText = promptMessage
        responseCompletionHandler = responseHandler

        if promptPanel == nil {
            createPromptPanel()
        }

        // `fittingSize` is unreliable on the same run-loop turn as a `@Published`
        // text change — it can return a collapsed height and `setFrame` + manual
        // `hostingView.frame` updates then fight `NSHostingView` constraints
        // (NSGenericException: Update Constraints pass recursion).
        DispatchQueue.main.async { [weak self] in
            self?.positionPromptPanelNearMouseCursor()
            self?.promptPanel?.orderFrontRegardless()
        }
    }

    /// Hides the prompt panel and resolves any pending response handler as
    /// `.rejected`. Resolving (rather than silently discarding) is critical:
    /// callers may be awaiting a continuation bridged from this handler, and
    /// a discarded handler would leave the awaiting Task hanging forever.
    /// A programmatic dismiss (e.g. tutor mode being disabled) is
    /// semantically equivalent to "no" — the user did not approve the
    /// observation — so `.rejected` is the correct resolution.
    func dismissPrompt() {
        let handler = responseCompletionHandler
        responseCompletionHandler = nil
        promptPanel?.orderOut(nil)
        handler?(.rejected)
    }

    /// Whether the prompt panel is currently visible.
    var isPromptVisible: Bool {
        promptPanel?.isVisible ?? false
    }

    // MARK: - Private: Button Handlers

    private func handleAcceptButtonTapped() {
        // Clear the handler before invoking it to prevent any possibility
        // of double-dispatch if the panel somehow re-receives events.
        let handler = responseCompletionHandler
        responseCompletionHandler = nil
        promptPanel?.orderOut(nil)
        handler?(.accepted)
    }

    private func handleRejectButtonTapped() {
        let handler = responseCompletionHandler
        responseCompletionHandler = nil
        promptPanel?.orderOut(nil)
        handler?(.rejected)
    }

    // MARK: - Private: Panel Creation

    private func createPromptPanel() {
        let promptView = ProactiveTutorPromptView(
            viewModel: promptViewModel,
            onAcceptButtonTapped: { [weak self] in
                self?.handleAcceptButtonTapped()
            },
            onRejectButtonTapped: { [weak self] in
                self?.handleRejectButtonTapped()
            }
        )
        .frame(maxWidth: promptPanelMaxWidth)

        let hostingView = NSHostingView(rootView: promptView)
        // Initial frame is small — resizePanelToFitContent will grow it once
        // the SwiftUI layout settles.
        let initialFrame = NSRect(x: 0, y: 0, width: promptPanelMaxWidth, height: 80)
        hostingView.frame = initialFrame

        let panel = NSPanel(
            contentRect: initialFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        // Floating level so it sits above other apps, non-activating so it
        // does not steal focus from the user's current app. Unlike the
        // cursor overlay, we DO accept mouse events because the yes/no
        // buttons must be clickable.
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = false
        panel.hidesOnDeactivate = false
        panel.isExcludedFromWindowsMenu = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = hostingView

        promptPanel = panel
    }

    /// Positions the prompt panel just to the right of the mouse cursor,
    /// flipping to the left or above the cursor if that would put it off
    /// the current screen.
    private func positionPromptPanelNearMouseCursor() {
        guard let promptPanel, let hostingView = promptPanel.contentView else { return }

        // Let SwiftUI compute its natural size from the new message text
        // before we position the panel.
        let fittingSize = hostingView.fittingSize
        let panelWidth = min(
            max(fittingSize.width, 160),
            promptPanelMaxWidth
        )
        let panelHeight = max(fittingSize.height, 80)

        let mouseLocation = NSEvent.mouseLocation
        var panelOriginX = mouseLocation.x + cursorOffsetHorizontal
        var panelOriginY = mouseLocation.y - cursorOffsetVertical - panelHeight

        if let screenContainingCursor = NSScreen.screens.first(where: {
            $0.frame.contains(mouseLocation)
        }) {
            let visibleFrame = screenContainingCursor.visibleFrame

            // If the bubble would go off the right edge, flip it to the
            // left of the cursor instead.
            if panelOriginX + panelWidth > visibleFrame.maxX {
                panelOriginX = mouseLocation.x - cursorOffsetHorizontal - panelWidth
            }

            // If the bubble would go below the bottom edge, flip it above
            // the cursor.
            if panelOriginY < visibleFrame.minY {
                panelOriginY = mouseLocation.y + cursorOffsetVertical
            }

            // Final clamp to the visible frame.
            panelOriginX = max(visibleFrame.minX, min(panelOriginX, visibleFrame.maxX - panelWidth))
            panelOriginY = max(visibleFrame.minY, min(panelOriginY, visibleFrame.maxY - panelHeight))
        }

        promptPanel.setFrame(
            NSRect(x: panelOriginX, y: panelOriginY, width: panelWidth, height: panelHeight),
            display: true
        )
    }
}

// MARK: - View Model

/// Observable state for the proactive tutor prompt. Kept as a view model
/// so the controller can push new message text without rebuilding the
/// SwiftUI hosting view.
@MainActor
final class ProactiveTutorPromptViewModel: ObservableObject {
    @Published var promptMessageText: String = ""
}

// MARK: - SwiftUI View

/// Speech-bubble-styled prompt view with inline approve/deny buttons.
/// Matches the overlay cursor aesthetic (dark surface, blue accent) via
/// the shared DS design system tokens.
struct ProactiveTutorPromptView: View {
    @ObservedObject var viewModel: ProactiveTutorPromptViewModel
    let onAcceptButtonTapped: () -> Void
    let onRejectButtonTapped: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            promptMessageText
            inlineButtonsRow
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(
                cornerRadius: DS.CornerRadius.large,
                style: .continuous
            )
            .fill(DS.Colors.surface1.opacity(0.98))
        )
        .overlay(
            RoundedRectangle(
                cornerRadius: DS.CornerRadius.large,
                style: .continuous
            )
            .stroke(DS.Colors.borderSubtle.opacity(0.55), lineWidth: 0.8)
        )
        .shadow(color: Color.black.opacity(0.35), radius: 14, x: 0, y: 6)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Message

    private var promptMessageText: some View {
        Text(viewModel.promptMessageText)
            .font(.system(size: 13, weight: .regular))
            .foregroundColor(DS.Colors.textPrimary)
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Inline Buttons

    private var inlineButtonsRow: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)

            Button(action: onRejectButtonTapped) {
                Text("No")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(ConsentPromptButtonStyle(variant: .secondary))
            .pointerCursor()
            .keyboardShortcut("n", modifiers: [])

            Button(action: onAcceptButtonTapped) {
                Text("Yes")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(ConsentPromptButtonStyle(variant: .primary))
            .pointerCursor()
            .keyboardShortcut("y", modifiers: [])
        }
    }
}

// MARK: - Consent Prompt Button Style

/// Reusable button style for the consent prompt's Yes/No buttons. Adds
/// hover + press states that match the cursor-bubble aesthetic: slight
/// brightness shift on hover, subtle scale + accent wash on press.
private struct ConsentPromptButtonStyle: ButtonStyle {
    enum Variant {
        case primary
        case secondary
    }

    let variant: Variant

    func makeBody(configuration: Configuration) -> some View {
        ConsentPromptButtonStyleBody(configuration: configuration, variant: variant)
    }
}

private struct ConsentPromptButtonStyleBody: View {
    let configuration: ButtonStyle.Configuration
    let variant: ConsentPromptButtonStyle.Variant
    @State private var isHovering: Bool = false

    var body: some View {
        configuration.label
            .foregroundColor(foregroundColor)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(
                    cornerRadius: DS.CornerRadius.small,
                    style: .continuous
                )
                .fill(currentFillColor)
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.12), value: isHovering)
            .onHover { hovering in
                isHovering = hovering
            }
    }

    private var foregroundColor: Color {
        switch variant {
        case .primary:   return DS.Colors.textOnAccent
        case .secondary: return DS.Colors.textSecondary
        }
    }

    private var currentFillColor: Color {
        switch variant {
        case .primary:
            if configuration.isPressed { return DS.Colors.accent.opacity(0.85) }
            return isHovering ? DS.Colors.accent.opacity(0.95) : DS.Colors.accent
        case .secondary:
            if configuration.isPressed { return DS.Colors.surface3 }
            return isHovering ? DS.Colors.surface3.opacity(0.9) : DS.Colors.surface3.opacity(0.8)
        }
    }
}
