//
//  CursorBubbleConsentPromptController.swift
//  claude-cursor
//
//  Terracotta consent pill that blooms out of the cursor when Claude wants
//  to run an action that requires user approval (currently used for
//  `start_automation_sequence`). Visually matches the NavigationBubbleView
//  "Click here" pill verbatim so the consent feels like an organic
//  extension of the cursor, not a modal dialog.
//
//  Unlike `CompanionResponseOverlay` (now deleted) this panel ACCEPTS mouse
//  events so the inline Yes/No pill buttons are clickable. The panel is
//  non-activating so tapping a button does not steal focus from the user's
//  current app.
//
//  The controller emits `.accepted` or `.rejectedByUser` through the
//  response handler. The `.didNotRespond` outcome is synthesized upstream
//  by `AutomationEngine`'s consent timeout — it calls
//  `beginTimeoutDismissal()` on this controller to swap the pill content
//  to a short "timed out — dismissing" message before hiding the panel.
//

import AppKit
import Combine
import SwiftUI

// MARK: - Controller

@MainActor
final class CursorBubbleConsentPromptController {

    private var consentPanel: NSPanel?
    private let consentViewModel = CursorBubbleConsentViewModel()
    private let pillTypewriter = CursorPillTypewriter()

    /// Maximum width for the pill bubble.
    private let consentPanelMaxWidth: CGFloat = 320

    /// Floors for `fittingSize` so a transient tiny value never collapses the
    /// `NSPanel` and triggers `NSHostingView` constraint thrash (see proactive
    /// tutor / menu bar panel fixes).
    private let consentPanelMinimumWidth: CGFloat = 160
    private let consentPanelMinimumHeight: CGFloat = 80

    /// Coalesces resize work during character streaming (~50ms) instead of
    /// calling `setFrame` on every appended character.
    private var debouncedConsentPanelResizeWorkItem: DispatchWorkItem?

    /// Horizontal / vertical offset from the cursor when positioning the
    /// panel. Matches the NavigationBubbleView offset (+10 / +18) so the
    /// consent pill feels like it blooms out of the cursor.
    private let cursorOffsetHorizontal: CGFloat = 10
    private let cursorOffsetVertical: CGFloat = 18

    /// Completion handler invoked exactly once when the user taps Yes or No
    /// (or dismisses the panel programmatically — that resolves as
    /// `.rejectedByUser`). `.didNotRespond` is not emitted through this
    /// handler; the timeout path clears the handler before swapping to the
    /// dismissal UX (see `beginTimeoutDismissal`).
    private var responseCompletionHandler: ((CursorBubbleConsentOutcome) -> Void)?

    /// Task that drives the pill text from typewriter events. Cancelled on
    /// dismiss / accept / reject / in-place replace / timeout.
    private var typewriterConsumerTask: Task<Void, Never>?

    /// Local key-down monitor — catches Return/Escape when the panel has key
    /// focus (rare given `nonactivatingPanel`, but possible).
    private var localKeyboardEventMonitor: Any?

    /// Global key-down monitor — catches Return/Escape while another app
    /// stays frontmost. Global monitors are listen-only, so the user's
    /// frontmost app still processes the key press too. Acceptable for
    /// the short-lived consent window; matches the pattern used in
    /// `LessonOverlayView`.
    private var globalKeyboardEventMonitor: Any?

    /// Gate for the 300ms VoiceOver `.layoutChanged` announcement. A new
    /// show / in-place replace rotates this token; the deferred task reads
    /// it before posting so we never announce against a torn-down panel or
    /// the previous stream's stale content.
    private var voiceOverAnnouncementToken: UUID?

    /// Work item that hides the panel 3 seconds after `beginTimeoutDismissal`
    /// swaps the pill content. Cancelled if a new `showConsent` arrives in
    /// the meantime so the panel doesn't disappear under the next prompt.
    private var timeoutDismissalWorkItem: DispatchWorkItem?

    // MARK: - Public API

    /// Shows the consent pill near the current cursor location. Streams the
    /// message text character-by-character with a 30–60ms cadence (matches
    /// the NavigationBubbleView "Click here" reveal). Once streaming
    /// completes, the Yes/No buttons fade in below the pill.
    ///
    /// If a consent pill is already visible when this is called, the old
    /// handler resolves as `.rejectedByUser` and the new message replaces
    /// the content in place — no `orderOut`, no single-frame flash.
    ///
    /// `responseHandler` is called exactly once with the user's choice. If
    /// the prompt is dismissed programmatically (see `dismissPrompt`) the
    /// handler resolves as `.rejectedByUser`.
    func showConsent(
        withMessage consentMessage: String,
        onResponse responseHandler: @escaping (CursorBubbleConsentOutcome) -> Void
    ) {
        let hadPendingHandler = responseCompletionHandler != nil

        // Resolve the prior handler first so the previous caller's await
        // unblocks before we overwrite shared state.
        if hadPendingHandler {
            let previousHandler = responseCompletionHandler
            responseCompletionHandler = nil
            previousHandler?(.rejectedByUser)
        }

        // Cancel anything that would mutate the pill state from the prior
        // stream or a pending timeout dismissal.
        pillTypewriter.cancelCurrentStream()
        typewriterConsumerTask?.cancel()
        typewriterConsumerTask = nil
        cancelDebouncedConsentPanelResize()
        cancelPendingTimeoutDismissal()

        if consentPanel == nil {
            createConsentPanel()
        }

        // Reset the view model — scale back to 0.5 so the pop animation
        // replays as the first character arrives, message cleared, buttons
        // hidden. Applies whether this is a first show or an in-place
        // replace.
        consentViewModel.messageText = ""
        consentViewModel.isShowingButtons = false
        consentViewModel.bubbleScale = 0.5

        responseCompletionHandler = responseHandler

        if !hadPendingHandler {
            // First-time show: position near the cursor, bring the panel
            // forward, and install the keyboard monitors. On an in-place
            // replace the panel is already visible and the monitors are
            // already installed.
            //
            // `fittingSize` is unreliable on the same run-loop turn as a `@Published`
            // text change — it can return a collapsed height and `setFrame` + manual
            // `hostingView.frame` updates then fight `NSHostingView` constraints
            // (NSGenericException: Update Constraints pass recursion).
            // Defer to the next run-loop turn so the three `@Published` resets above
            // (messageText, isShowingButtons, bubbleScale) commit before anyone reads
            // `fittingSize`. Matches the proactive tutor fix in
            // ProactiveTutorPromptController.swift.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.positionConsentPanelNearMouseCursor()
                runAppKitMutationCatchingNSException(
                    operationLabel: "CursorBubbleConsent.orderFrontRegardless"
                ) {
                    self.consentPanel?.orderFrontRegardless()
                }
                self.installKeyboardEventMonitorsIfNeeded()
            }
        }

        withAnimation(.spring(response: 0.4, dampingFraction: 0.6)) {
            consentViewModel.bubbleScale = 1.0
        }

        scheduleVoiceOverAnnouncement()
        consumeTypewriterStream(for: consentMessage)
    }

    /// Hides the panel and resolves any pending handler as `.rejectedByUser`.
    func dismissPrompt() {
        pillTypewriter.cancelCurrentStream()
        typewriterConsumerTask?.cancel()
        typewriterConsumerTask = nil
        cancelDebouncedConsentPanelResize()
        cancelPendingTimeoutDismissal()
        voiceOverAnnouncementToken = nil
        removeKeyboardEventMonitors()

        let handler = responseCompletionHandler
        responseCompletionHandler = nil
        // Teardown path — swallow any NSException here; we're already tearing
        // down and don't want a stray AppKit throw to block handler resolution.
        runAppKitMutationCatchingNSException(
            operationLabel: "CursorBubbleConsent.dismissPrompt.orderOut"
        ) {
            self.consentPanel?.orderOut(nil)
        }
        handler?(.rejectedByUser)
    }

    /// Swaps the pill content to "timed out — dismissing" for 3 seconds,
    /// then hides the panel. Invoked by `AutomationEngine` when the consent
    /// continuation times out. The response handler is cleared first so the
    /// subsequent hide doesn't fire a duplicate `.rejectedByUser` — the
    /// caller has already resolved the upstream continuation as
    /// `.didNotRespond`.
    func beginTimeoutDismissal() {
        responseCompletionHandler = nil

        pillTypewriter.cancelCurrentStream()
        typewriterConsumerTask?.cancel()
        typewriterConsumerTask = nil
        cancelDebouncedConsentPanelResize()
        cancelPendingTimeoutDismissal()

        consentViewModel.isShowingButtons = false
        consentViewModel.messageText = "timed out — dismissing"
        scheduleDebouncedConsentPanelResize()

        let dismissalWorkItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.voiceOverAnnouncementToken = nil
            self.removeKeyboardEventMonitors()
            runAppKitMutationCatchingNSException(
                operationLabel: "CursorBubbleConsent.timeoutDismissal.orderOut"
            ) {
                self.consentPanel?.orderOut(nil)
            }
            self.timeoutDismissalWorkItem = nil
        }
        timeoutDismissalWorkItem = dismissalWorkItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0, execute: dismissalWorkItem)
    }

    /// Whether the consent pill is currently visible.
    var isConsentVisible: Bool {
        consentPanel?.isVisible ?? false
    }

    // MARK: - Private: Typewriter Consumer

    /// Reads the typewriter's `AsyncStream` and applies each event to the
    /// view model. `.character` appends + schedules a debounced resize.
    /// `.completed` pauses briefly so the final word lands, then fades the
    /// Yes/No buttons in and does a final resize. `.cancelled` is a no-op
    /// because the dismiss / replace path already owns the UI teardown.
    private func consumeTypewriterStream(for fullMessage: String) {
        let eventStream = pillTypewriter.stream(text: fullMessage)

        typewriterConsumerTask?.cancel()
        typewriterConsumerTask = Task { @MainActor [weak self] in
            // Guarantee the controller's reference to this Task is cleared on
            // every exit path so a subsequent `showConsent` never sees a stale
            // pointer to a finished Task.
            defer { self?.typewriterConsumerTask = nil }

            for await event in eventStream {
                guard let self else { return }
                switch event {
                case .character(let nextCharacter):
                    self.consentViewModel.messageText.append(nextCharacter)
                    self.scheduleDebouncedConsentPanelResize()

                case .completed:
                    try? await Task.sleep(for: .milliseconds(150))
                    guard !Task.isCancelled else { return }
                    // If the user rejected (or a concurrent prompt replaced us)
                    // during the 150ms pause, the handler is cleared — don't
                    // flip the buttons in on a prompt that's already resolved.
                    guard self.responseCompletionHandler != nil else { return }
                    self.cancelDebouncedConsentPanelResize()
                    withAnimation(.easeOut(duration: 0.25)) {
                        self.consentViewModel.isShowingButtons = true
                    }
                    self.resizeConsentPanelToFitContent()

                case .cancelled:
                    return
                }
            }
        }
    }

    // MARK: - Private: Button Handlers

    private func handleAcceptButtonTapped() {
        pillTypewriter.cancelCurrentStream()
        typewriterConsumerTask?.cancel()
        typewriterConsumerTask = nil
        cancelDebouncedConsentPanelResize()
        cancelPendingTimeoutDismissal()
        voiceOverAnnouncementToken = nil
        removeKeyboardEventMonitors()

        let handler = responseCompletionHandler
        responseCompletionHandler = nil
        runAppKitMutationCatchingNSException(
            operationLabel: "CursorBubbleConsent.accept.orderOut"
        ) {
            self.consentPanel?.orderOut(nil)
        }
        handler?(.accepted)
    }

    private func handleRejectButtonTapped() {
        pillTypewriter.cancelCurrentStream()
        typewriterConsumerTask?.cancel()
        typewriterConsumerTask = nil
        cancelDebouncedConsentPanelResize()
        cancelPendingTimeoutDismissal()
        voiceOverAnnouncementToken = nil
        removeKeyboardEventMonitors()

        let handler = responseCompletionHandler
        responseCompletionHandler = nil
        runAppKitMutationCatchingNSException(
            operationLabel: "CursorBubbleConsent.reject.orderOut"
        ) {
            self.consentPanel?.orderOut(nil)
        }
        handler?(.rejectedByUser)
    }

    // MARK: - Private: Keyboard Monitors

    private func installKeyboardEventMonitorsIfNeeded() {
        if globalKeyboardEventMonitor == nil {
            globalKeyboardEventMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: .keyDown
            ) { [weak self] keyDownEvent in
                // NSEvent is not Sendable, so capture the one value we need
                // (keyCode is UInt16) before hopping to the main actor.
                let capturedKeyCode = keyDownEvent.keyCode
                Task { @MainActor in
                    self?.handleConsentKeyDown(keyCode: capturedKeyCode)
                }
            }
        }
        if localKeyboardEventMonitor == nil {
            localKeyboardEventMonitor = NSEvent.addLocalMonitorForEvents(
                matching: .keyDown
            ) { [weak self] keyDownEvent in
                guard let self else { return keyDownEvent }
                let wasHandled = self.handleConsentKeyDown(keyCode: keyDownEvent.keyCode)
                return wasHandled ? nil : keyDownEvent
            }
        }
    }

    private func removeKeyboardEventMonitors() {
        if let monitorReference = globalKeyboardEventMonitor {
            NSEvent.removeMonitor(monitorReference)
            globalKeyboardEventMonitor = nil
        }
        if let monitorReference = localKeyboardEventMonitor {
            NSEvent.removeMonitor(monitorReference)
            localKeyboardEventMonitor = nil
        }
    }

    /// Returns true when the key was consumed by the consent pill.
    /// Return/Escape only fire when a response handler is pending so we
    /// never double-resolve during the 3s timeout-dismissal window.
    @discardableResult
    private func handleConsentKeyDown(keyCode: UInt16) -> Bool {
        guard responseCompletionHandler != nil else { return false }

        // Keycode 36 is Return on every US/INTL Mac keyboard. We only
        // accept via Return once the Yes button is actually visible so the
        // user can't "accept" a request whose text hasn't finished streaming.
        if keyCode == 36, consentViewModel.isShowingButtons {
            handleAcceptButtonTapped()
            return true
        }
        // Keycode 53 is Escape — rejects mid-stream too, matching mouse
        // behavior where the No button appears after streaming but users
        // can also abort by clicking outside intent anytime.
        if keyCode == 53 {
            handleRejectButtonTapped()
            return true
        }
        return false
    }

    // MARK: - Private: Accessibility Announcement

    /// Posts an `.layoutChanged` VoiceOver announcement ~300ms after the
    /// pill appears. The delay avoids racing VoiceOver's own window-
    /// appeared announcement. The UUID token guards the deferred post so
    /// it skips if the panel has since been torn down or replaced by a
    /// newer prompt.
    private func scheduleVoiceOverAnnouncement() {
        let announcementToken = UUID()
        voiceOverAnnouncementToken = announcementToken

        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self else { return }
            guard self.voiceOverAnnouncementToken == announcementToken else { return }
            guard let consentPanel = self.consentPanel,
                  consentPanel.isVisible else { return }
            runAppKitMutationCatchingNSException(
                operationLabel: "CursorBubbleConsent.postVoiceOverAnnouncement"
            ) {
                NSAccessibility.post(
                    element: consentPanel,
                    notification: .layoutChanged
                )
            }
        }
    }

    // MARK: - Private: Panel Creation

    private func createConsentPanel() {
        let consentView = CursorBubbleConsentView(
            viewModel: consentViewModel,
            onAcceptButtonTapped: { [weak self] in
                self?.handleAcceptButtonTapped()
            },
            onRejectButtonTapped: { [weak self] in
                self?.handleRejectButtonTapped()
            }
        )
        .frame(maxWidth: consentPanelMaxWidth)

        let initialFrame = NSRect(
            x: 0,
            y: 0,
            width: consentPanelMaxWidth,
            height: consentPanelMinimumHeight
        )

        runAppKitMutationCatchingNSException(
            operationLabel: "CursorBubbleConsent.createPanel"
        ) {
            let hostingView = NSHostingView(rootView: consentView)
            hostingView.frame = initialFrame

            let panel = NSPanel(
                contentRect: initialFrame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )

            // Status-bar level keeps the pill above the frontmost app, but
            // non-activating + mouse-accepting so the user can tap Yes/No
            // without ClaudeCursor stealing focus.
            panel.level = .statusBar
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.hidesOnDeactivate = false
            panel.ignoresMouseEvents = false
            panel.isExcludedFromWindowsMenu = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            panel.contentView = hostingView

            self.consentPanel = panel
        }
    }

    // MARK: - Private: Layout

    private func cancelDebouncedConsentPanelResize() {
        debouncedConsentPanelResizeWorkItem?.cancel()
        debouncedConsentPanelResizeWorkItem = nil
    }

    private func scheduleDebouncedConsentPanelResize() {
        debouncedConsentPanelResizeWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.resizeConsentPanelToFitContent()
            self?.debouncedConsentPanelResizeWorkItem = nil
        }
        debouncedConsentPanelResizeWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: workItem)
    }

    private func cancelPendingTimeoutDismissal() {
        timeoutDismissalWorkItem?.cancel()
        timeoutDismissalWorkItem = nil
    }

    /// Positions the consent pill just to the right of (and slightly below)
    /// the cursor, flipping to the opposite side or above if it would
    /// otherwise clip off the screen. Falls back to `NSScreen.main` when
    /// the cursor's screen has disappeared (e.g. external monitor unplug
    /// mid-show) so a stray display hotplug doesn't strand the panel
    /// off-screen.
    private func positionConsentPanelNearMouseCursor() {
        guard let consentPanel, let hostingView = consentPanel.contentView else { return }

        let caughtExceptionDiagnostic = runAppKitMutationCatchingNSException(
            operationLabel: "CursorBubbleConsent.positionPanel"
        ) {
            // Flush any pending SwiftUI invalidation so `fittingSize` measures
            // the committed state instead of a mid-mutation snapshot. Skipping
            // this is the trigger for the Update Constraints pass recursion.
            hostingView.layoutSubtreeIfNeeded()

            let fittingSize = hostingView.fittingSize
            // `fittingSize` can return `.zero` transiently mid-layout. Bail so
            // we don't collapse the panel to a zero frame, which itself can
            // trigger an invalid-argument NSException on subsequent setFrame.
            guard fittingSize.width > 0, fittingSize.height > 0 else { return }

            let panelWidth = min(
                max(fittingSize.width, self.consentPanelMinimumWidth),
                self.consentPanelMaxWidth
            )
            let panelHeight = max(fittingSize.height, self.consentPanelMinimumHeight)

            let mouseLocation = NSEvent.mouseLocation
            var panelOriginX = mouseLocation.x + self.cursorOffsetHorizontal
            var panelOriginY = mouseLocation.y - self.cursorOffsetVertical - panelHeight

            let screenForPositioning = NSScreen.screens.first {
                $0.frame.contains(mouseLocation)
            } ?? NSScreen.main

            if let screenForPositioning {
                let visibleFrame = screenForPositioning.visibleFrame

                if panelOriginX + panelWidth > visibleFrame.maxX {
                    panelOriginX = mouseLocation.x - self.cursorOffsetHorizontal - panelWidth
                }

                if panelOriginY < visibleFrame.minY {
                    panelOriginY = mouseLocation.y + self.cursorOffsetVertical
                }

                panelOriginX = max(
                    visibleFrame.minX,
                    min(panelOriginX, visibleFrame.maxX - panelWidth)
                )
                panelOriginY = max(
                    visibleFrame.minY,
                    min(panelOriginY, visibleFrame.maxY - panelHeight)
                )
            }

            // `display: false` lets AppKit schedule the redraw on the next
            // runloop turn — forcing an immediate synchronous redraw is the
            // trigger for the nested constraints pass.
            consentPanel.setFrame(
                NSRect(x: panelOriginX, y: panelOriginY, width: panelWidth, height: panelHeight),
                display: false
            )
        }

        if caughtExceptionDiagnostic != nil {
            handleCaughtAppKitException()
        }
    }

    /// Grows the panel frame as the message streams in and again when the
    /// button row fades in, so nothing gets clipped at either step.
    private func resizeConsentPanelToFitContent() {
        guard let consentPanel,
              let hostingView = consentPanel.contentView else {
            return
        }

        let caughtExceptionDiagnostic = runAppKitMutationCatchingNSException(
            operationLabel: "CursorBubbleConsent.resizePanel"
        ) {
            // Drain the SwiftUI layout queue before reading `fittingSize` so
            // a concurrent `@Published` mutation (typewriter character append)
            // doesn't collide with an AppKit constraints pass mid-measure.
            hostingView.layoutSubtreeIfNeeded()

            let fittingSize = hostingView.fittingSize
            guard fittingSize.width > 0, fittingSize.height > 0 else { return }

            let clampedWidth = min(
                max(fittingSize.width, self.consentPanelMinimumWidth),
                self.consentPanelMaxWidth
            )
            let newHeight = max(fittingSize.height, self.consentPanelMinimumHeight)

            var frame = consentPanel.frame
            let heightDelta = newHeight - frame.height
            frame.size = CGSize(width: clampedWidth, height: newHeight)
            // Grow upward, keeping the bottom edge pinned near the cursor so
            // the bubble appears to expand out of the cursor rather than push
            // the cursor away.
            frame.origin.y -= heightDelta

            consentPanel.setFrame(frame, display: false)
        }

        if caughtExceptionDiagnostic != nil {
            handleCaughtAppKitException()
        }
    }

    /// Graceful fallback when an NSException slips past every prevention
    /// layer: resolves the handler as `.rejectedByUser`, tears the panel
    /// down (wrapped so a teardown exception is swallowed), and publishes
    /// a one-line status so the user knows the attempt failed rather than
    /// silently hung. No retry — NSException indicates programmer error.
    private func handleCaughtAppKitException() {
        cancelDebouncedConsentPanelResize()
        cancelPendingTimeoutDismissal()
        pillTypewriter.cancelCurrentStream()
        typewriterConsumerTask?.cancel()
        typewriterConsumerTask = nil
        voiceOverAnnouncementToken = nil
        removeKeyboardEventMonitors()

        let handler = responseCompletionHandler
        responseCompletionHandler = nil
        runAppKitMutationCatchingNSException(
            operationLabel: "CursorBubbleConsent.orderOutAfterException"
        ) {
            self.consentPanel?.orderOut(nil)
        }
        handler?(.rejectedByUser)
    }
}

// MARK: - View Model

@MainActor
final class CursorBubbleConsentViewModel: ObservableObject {
    /// Currently-streamed consent message. Grows one character at a time.
    @Published var messageText: String = ""

    /// Drives the pop-scale entrance — 0.5 on show, spring-animated to 1.0.
    @Published var bubbleScale: CGFloat = 0.5

    /// Whether the Yes/No button row is visible. Flipped to true once the
    /// message finishes streaming; the switch is wrapped in `withAnimation`
    /// by the controller so the buttons fade + slide in.
    @Published var isShowingButtons: Bool = false
}

// MARK: - SwiftUI View

/// Terracotta consent bubble with a streaming message and inline Yes/No
/// buttons. Styling matches `NavigationBubbleView` in `OverlayWindow.swift`
/// verbatim so both cursor-side pills feel like the same component family.
struct CursorBubbleConsentView: View {
    @ObservedObject var viewModel: CursorBubbleConsentViewModel
    let onAcceptButtonTapped: () -> Void
    let onRejectButtonTapped: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            messagePill
            if viewModel.isShowingButtons {
                inlineButtonsRow
                    .transition(
                        .asymmetric(
                            insertion: .opacity.combined(with: .offset(y: 8)),
                            removal: .opacity
                        )
                    )
            }
        }
        .scaleEffect(viewModel.bubbleScale, anchor: .topLeading)
    }

    // MARK: - Message Pill

    /// The terracotta message pill. Styling comes from the shared
    /// `CursorPillBubble` so the consent surface and the navigation pointer
    /// bubble stay perceptually identical. Scale is pinned at 1.0 because
    /// the outer `VStack.scaleEffect` drives the pop-in animation (and also
    /// scales the Yes/No buttons with the pill as a single unit).
    private var messagePill: some View {
        CursorPillBubble(
            text: viewModel.messageText,
            scale: 1.0,
            sizing: .constrained(maxWidth: 300)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Claude automation request: \(viewModel.messageText)")
        .accessibilityHint("Return or Y to accept, Escape or N to decline")
    }

    // MARK: - Button Row

    private var inlineButtonsRow: some View {
        HStack(spacing: 6) {
            Button(action: onRejectButtonTapped) {
                Text("No")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(CursorBubbleConsentButtonStyle(variant: .secondary))
            .keyboardShortcut("n", modifiers: [])
            .keyboardShortcut(.escape, modifiers: [])
            .accessibilityLabel("Decline automation")

            Button(action: onAcceptButtonTapped) {
                Text("Yes")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(CursorBubbleConsentButtonStyle(variant: .primary))
            .keyboardShortcut("y", modifiers: [])
            .keyboardShortcut(.return, modifiers: [])
            .accessibilityLabel("Accept automation")
        }
        .padding(.leading, 4)
    }
}

// MARK: - Button Style

/// Pill-shaped Yes/No buttons that visually extend the consent bubble.
/// Primary (Yes) is the same overlayCursorBrand as the bubble itself;
/// secondary (No) is a darker translucent variant so the pair reads as a
/// single control cluster.
private struct CursorBubbleConsentButtonStyle: ButtonStyle {
    enum Variant {
        case primary
        case secondary
    }

    let variant: Variant

    func makeBody(configuration: Configuration) -> some View {
        CursorBubbleConsentButtonStyleBody(configuration: configuration, variant: variant)
    }
}

private struct CursorBubbleConsentButtonStyleBody: View {
    let configuration: ButtonStyle.Configuration
    let variant: CursorBubbleConsentButtonStyle.Variant
    @State private var isHovering: Bool = false

    var body: some View {
        configuration.label
            .foregroundColor(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(currentFillColor)
                    .shadow(
                        color: DS.Colors.overlayCursorBrand.opacity(variant == .primary ? 0.5 : 0),
                        radius: 6,
                        x: 0,
                        y: 0
                    )
            )
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.12), value: isHovering)
            .onHover { hovering in
                isHovering = hovering
                if hovering {
                    NSCursor.pointingHand.push()
                } else {
                    NSCursor.pop()
                }
            }
    }

    private var currentFillColor: Color {
        switch variant {
        case .primary:
            if configuration.isPressed { return DS.Colors.overlayCursorBrand.opacity(0.85) }
            return isHovering ? DS.Colors.overlayCursorBrand : DS.Colors.overlayCursorBrand.opacity(0.95)
        case .secondary:
            if configuration.isPressed { return DS.Colors.overlayCursorBrand.opacity(0.35) }
            return isHovering
                ? DS.Colors.overlayCursorBrand.opacity(0.45)
                : DS.Colors.overlayCursorBrand.opacity(0.35)
        }
    }
}
