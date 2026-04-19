//
//  LessonOverlayView.swift
//  claude-cursor
//
//  Compact floating pill panel for YouTube tutorial lesson steps. Renders a
//  dark surface pill with step text, prev/next controls, and close. The panel
//  is a non-activating NSPanel that follows the cursor (like the navigation
//  bubble) with the PiP video anchored directly below via `onPillFrameDidChange`.
//

import AppKit
import Combine
import SwiftUI

// MARK: - Layout measurement

private struct LessonPillLayoutSizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

// MARK: - Controller

/// Owns the compact NSPanel that hosts the lesson step pill. Handles panel
/// lifecycle, keyboard + mouse-follow monitors, step-advance callbacks back to
/// `CompanionManager`, and exposes the pill's screen frame so the PiP video
/// can be anchored directly below.
@MainActor
final class LessonOverlayController {

    private var pillPanel: NSPanel?
    let lessonOverlayViewModel = LessonOverlayViewModel()
    private var globalKeyboardEventMonitor: Any?
    private var localKeyboardEventMonitor: Any?
    private var globalMouseMoveEventMonitor: Any?
    private var pillLayoutCancellable: AnyCancellable?
    private var lastMouseFollowSystemUptime: TimeInterval = 0

    /// Invoked when the step index changes. The second flag is true when the
    /// user moved via next/prev (or keyboard) so the companion should seek
    /// the PiP to that step's timestamp; false for playback-driven advances.
    var onStepIndexChanged: ((Int, Bool) -> Void)?

    /// Invoked when the user closes the overlay via the close button or
    /// cancels the lesson. The companion should exit lesson mode.
    var onLessonDismissed: (() -> Void)?

    /// Fired after the pill moves or resizes so `CompanionManager` can
    /// re-anchor the PiP player.
    var onPillFrameDidChange: (() -> Void)?

    private let minimumPillPanelWidth: CGFloat = 280
    private let minimumPillPanelHeight: CGFloat = 44

    // MARK: - Public API

    /// Shows the pill for the given lesson, starting at `initialStepIndex`.
    /// Creates the panel on first call and reuses it across subsequent shows.
    func showLessonOverlay(
        forLesson lesson: Lesson,
        startingAtStepIndex initialStepIndex: Int
    ) {
        refreshMaxPillWidthForScreenContainingMouse()
        lessonOverlayViewModel.loadLesson(
            lesson: lesson,
            initialStepIndex: initialStepIndex
        )
        lessonOverlayViewModel.onStepChangeInternal = { [weak self] newStepIndex, shouldSeekVideo in
            self?.onStepIndexChanged?(newStepIndex, shouldSeekVideo)
        }
        lessonOverlayViewModel.onCloseTapped = { [weak self] in
            self?.hideLessonOverlay()
            self?.onLessonDismissed?()
        }

        if pillPanel == nil {
            createPillPanel()
            startObservingPillLayoutSizeChanges()
        }

        applyDefaultPillPanelFrameIfNeeded()
        positionPillBesideCursorPreservingSize()

        lessonOverlayViewModel.pillOpacity = 0.0
        lessonOverlayViewModel.pillScale = 0.85
        pillPanel?.orderFrontRegardless()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.lessonOverlayViewModel.pillOpacity = 1.0
            self?.lessonOverlayViewModel.pillScale = 1.0
        }

        installKeyboardEventMonitors()
        installMouseMoveMonitorIfNeeded()
    }

    /// Hides the pill with a fade-out + scale-down animation, then removes
    /// the panel from the screen after the animation completes.
    func hideLessonOverlay() {
        removeKeyboardEventMonitors()
        removeMouseMoveMonitor()

        lessonOverlayViewModel.pillOpacity = 0.0
        lessonOverlayViewModel.pillScale = 0.85

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.pillPanel?.orderOut(nil)
        }
    }

    /// Programmatically moves to a specific step. Used when the PiP video
    /// timestamp crosses a step boundary and the UI should auto-advance.
    func advanceToStep(atIndex targetStepIndex: Int) {
        lessonOverlayViewModel.goToStep(
            atIndex: targetStepIndex,
            shouldSeekVideoToStepStart: false
        )
    }

    /// Whether the pill is currently visible on screen.
    var isLessonOverlayVisible: Bool {
        pillPanel?.isVisible ?? false
    }

    /// The pill panel's current frame in screen coordinates. Used by
    /// `CompanionManager` to position the PiP video directly below.
    var currentPillPanelFrame: NSRect? {
        guard let pillPanel, pillPanel.isVisible else { return nil }
        return pillPanel.frame
    }

    // MARK: - Panel Lifecycle

    private func createPillPanel() {
        let pillContentView = LessonStepPillView(viewModel: lessonOverlayViewModel)
        let hostingView = NSHostingView(rootView: pillContentView)
        hostingView.frame = NSRect(
            x: 0,
            y: 0,
            width: minimumPillPanelWidth,
            height: minimumPillPanelHeight
        )

        let panel = NSPanel(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: minimumPillPanelWidth,
                height: minimumPillPanelHeight
            ),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // SwiftUI draws the card shadow; a second window shadow stacks oddly
        // and can read as colored bands along the panel edges.
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = false
        panel.isExcludedFromWindowsMenu = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = hostingView

        pillPanel = panel
    }

    private func applyDefaultPillPanelFrameIfNeeded() {
        guard let pillPanel else { return }
        if pillPanel.frame.width < minimumPillPanelWidth
            || pillPanel.frame.height < minimumPillPanelHeight {
            pillPanel.setFrame(
                NSRect(
                    x: pillPanel.frame.origin.x,
                    y: pillPanel.frame.origin.y,
                    width: max(pillPanel.frame.width, minimumPillPanelWidth),
                    height: max(pillPanel.frame.height, minimumPillPanelHeight)
                ),
                display: false
            )
        }
    }

    private func startObservingPillLayoutSizeChanges() {
        pillLayoutCancellable?.cancel()
        pillLayoutCancellable = Publishers.CombineLatest(
            lessonOverlayViewModel.$measuredPillLayoutSize,
            lessonOverlayViewModel.$currentStepIndex
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] measuredSize, _ in
            self?.applyMeasuredPillLayoutSize(measuredSize)
        }
    }

    private func applyMeasuredPillLayoutSize(_ measuredSize: CGSize) {
        guard let pillPanel,
              pillPanel.isVisible,
              measuredSize.width > 8,
              measuredSize.height > 8 else {
            return
        }
        let clampedWidth = max(minimumPillPanelWidth, measuredSize.width)
        let clampedHeight = max(minimumPillPanelHeight, measuredSize.height)
        let origin = pillPanel.frame.origin
        pillPanel.setFrame(
            NSRect(x: origin.x, y: origin.y, width: clampedWidth, height: clampedHeight),
            display: true
        )
        positionPillBesideCursorPreservingSize()
    }

    private func refreshMaxPillWidthForScreenContainingMouse() {
        let screenForWidth = screenContainingMouseLocation() ?? NSScreen.main
        guard let screen = screenForWidth else { return }
        let visibleFrame = screen.visibleFrame
        let horizontalMargin: CGFloat = 24
        let computedMax = min(
            720,
            max(minimumPillPanelWidth, visibleFrame.width - horizontalMargin * 2)
        )
        lessonOverlayViewModel.maxPillContentWidth = computedMax
    }

    private func screenContainingMouseLocation() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first { screen in
            NSMouseInRect(mouseLocation, screen.frame, false)
        }
    }

    /// Positions the pill to the right of and slightly below the cursor
    /// (same AppKit Y-down convention as the navigation bubble), with extra
    /// horizontal offset so the tip clears the buddy triangle.
    private func positionPillBesideCursorPreservingSize() {
        guard let pillPanel, pillPanel.isVisible else { return }
        let mouseLocation = NSEvent.mouseLocation
        let screen =
            screenContainingMouseLocation() ?? NSScreen.main
        guard let activeScreen = screen else { return }
        let visibleFrame = activeScreen.visibleFrame

        let panelWidth = pillPanel.frame.width
        let panelHeight = pillPanel.frame.height
        let horizontalOffsetFromCursor: CGFloat = 52
        // More negative Y places the panel lower — bottom-right of the buddy
        // hand — without changing horizontal alignment.
        let verticalOffsetFromCursor: CGFloat = -92

        var originX = mouseLocation.x + horizontalOffsetFromCursor
        var originY = mouseLocation.y + verticalOffsetFromCursor

        let edgeMargin: CGFloat = 8
        originX = min(
            max(visibleFrame.minX + edgeMargin, originX),
            visibleFrame.maxX - panelWidth - edgeMargin
        )
        originY = min(
            max(visibleFrame.minY + edgeMargin, originY),
            visibleFrame.maxY - panelHeight - edgeMargin
        )

        pillPanel.setFrameOrigin(NSPoint(x: originX, y: originY))
        onPillFrameDidChange?()
    }

    private func handleGlobalMouseMovedForLessonPillThrottled() {
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastMouseFollowSystemUptime < (1.0 / 45.0) {
            return
        }
        lastMouseFollowSystemUptime = now
        positionPillBesideCursorPreservingSize()
    }

    // MARK: - Keyboard Shortcuts

    private func installKeyboardEventMonitors() {
        removeKeyboardEventMonitors()

        globalKeyboardEventMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: .keyDown
        ) { [weak self] keyDownEvent in
            self?.handleLessonKeyDown(keyCode: keyDownEvent.keyCode)
        }

        localKeyboardEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: .keyDown
        ) { [weak self] keyDownEvent in
            guard let self = self else { return keyDownEvent }
            let handled = self.handleLessonKeyDown(keyCode: keyDownEvent.keyCode)
            return handled ? nil : keyDownEvent
        }
    }

    private func installMouseMoveMonitorIfNeeded() {
        removeMouseMoveMonitor()
        globalMouseMoveEventMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [
                .mouseMoved,
                .leftMouseDragged,
                .rightMouseDragged,
                .otherMouseDragged
            ]
        ) { [weak self] _ in
            self?.handleGlobalMouseMovedForLessonPillThrottled()
        }
    }

    @discardableResult
    private func handleLessonKeyDown(keyCode: UInt16) -> Bool {
        switch keyCode {
        case 123: // Left arrow
            lessonOverlayViewModel.goToPreviousStep()
            return true
        case 124: // Right arrow
            lessonOverlayViewModel.goToNextStep()
            return true
        case 53: // Escape
            hideLessonOverlay()
            onLessonDismissed?()
            return true
        default:
            return false
        }
    }

    private func removeKeyboardEventMonitors() {
        if let monitor = globalKeyboardEventMonitor {
            NSEvent.removeMonitor(monitor)
            globalKeyboardEventMonitor = nil
        }
        if let monitor = localKeyboardEventMonitor {
            NSEvent.removeMonitor(monitor)
            localKeyboardEventMonitor = nil
        }
    }

    private func removeMouseMoveMonitor() {
        if let monitor = globalMouseMoveEventMonitor {
            NSEvent.removeMonitor(monitor)
            globalMouseMoveEventMonitor = nil
        }
    }
}

// MARK: - View Model

@MainActor
final class LessonOverlayViewModel: ObservableObject {
    @Published var activeLesson: Lesson?
    @Published var currentStepIndex: Int = 0
    @Published var maxPillContentWidth: CGFloat = 720
    @Published private(set) var measuredPillLayoutSize: CGSize = .zero
    @Published var pillOpacity: Double = 0.0
    @Published var pillScale: CGFloat = 0.85

    var onStepChangeInternal: ((Int, Bool) -> Void)?
    var onCloseTapped: (() -> Void)?

    var currentStep: LessonStep? {
        guard let lesson = activeLesson,
              currentStepIndex >= 0,
              currentStepIndex < lesson.steps.count else {
            return nil
        }
        return lesson.steps[currentStepIndex]
    }

    var totalStepCount: Int {
        activeLesson?.steps.count ?? 0
    }

    func loadLesson(lesson: Lesson, initialStepIndex: Int) {
        activeLesson = lesson
        let clampedInitialIndex = max(
            0,
            min(initialStepIndex, max(0, lesson.steps.count - 1))
        )
        currentStepIndex = clampedInitialIndex
    }

    func goToNextStep() {
        guard currentStepIndex < totalStepCount - 1 else { return }
        currentStepIndex += 1
        onStepChangeInternal?(currentStepIndex, true)
    }

    func goToPreviousStep() {
        guard currentStepIndex > 0 else { return }
        currentStepIndex -= 1
        onStepChangeInternal?(currentStepIndex, true)
    }

    func goToStep(atIndex targetStepIndex: Int, shouldSeekVideoToStepStart: Bool) {
        guard let lesson = activeLesson,
              targetStepIndex >= 0,
              targetStepIndex < lesson.steps.count,
              targetStepIndex != currentStepIndex else {
            return
        }
        currentStepIndex = targetStepIndex
        onStepChangeInternal?(currentStepIndex, shouldSeekVideoToStepStart)
    }

    func reportPillLayoutSize(_ newSize: CGSize) {
        guard newSize.width > 1, newSize.height > 1 else { return }
        if abs(measuredPillLayoutSize.width - newSize.width) > 0.5
            || abs(measuredPillLayoutSize.height - newSize.height) > 0.5 {
            measuredPillLayoutSize = newSize
        }
    }
}

// MARK: - SwiftUI Pill View

struct LessonStepPillView: View {
    @ObservedObject var viewModel: LessonOverlayViewModel

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            previousStepButton
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 6) {
                Text(stepCounterLabel)
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundColor(DS.Colors.overlayCursorBrand)

                Text(stepInstructionDisplayText)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textPrimary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(5)
                    .fixedSize(horizontal: false, vertical: true)
                    .animation(.easeInOut(duration: 0.2), value: viewModel.currentStepIndex)
            }
            .frame(maxWidth: viewModel.maxPillContentWidth, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                nextStepButton
                closeButton
            }
            .padding(.top, 2)
        }
        .padding(.leading, 10)
        .padding(.trailing, 10)
        .padding(.vertical, 11)
        .frame(maxWidth: viewModel.maxPillContentWidth + 120)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                .fill(DS.Colors.surface2)
        )
        .shadow(
            color: Color.black.opacity(0.35),
            radius: 14,
            x: 0,
            y: 6
        )
        .opacity(viewModel.pillOpacity)
        .scaleEffect(viewModel.pillScale)
        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: viewModel.pillOpacity)
        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: viewModel.pillScale)
        .background(
            GeometryReader { geometry in
                Color.clear.preference(
                    key: LessonPillLayoutSizeKey.self,
                    value: geometry.size
                )
            }
        )
        .onPreferenceChange(LessonPillLayoutSizeKey.self) { newSize in
            viewModel.reportPillLayoutSize(newSize)
        }
    }

    private var previousStepButton: some View {
        Button(action: { viewModel.goToPreviousStep() }) {
            Image(systemName: "chevron.left")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 26, height: 26)
                .background(
                    Circle().fill(Color.white.opacity(isAtFirstStep ? 0.08 : 0.18))
                )
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .disabled(isAtFirstStep)
        .opacity(isAtFirstStep ? 0.4 : 1.0)
        .help("Previous step (←)")
    }

    private var nextStepButton: some View {
        Button(action: { viewModel.goToNextStep() }) {
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 26, height: 26)
                .background(
                    Circle().fill(Color.white.opacity(isAtLastStep ? 0.08 : 0.18))
                )
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .disabled(isAtLastStep)
        .opacity(isAtLastStep ? 0.4 : 1.0)
        .help("Next step (→)")
    }

    private var closeButton: some View {
        Button(action: { viewModel.onCloseTapped?() }) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(.white.opacity(0.85))
                .frame(width: 22, height: 22)
                .background(
                    Circle().fill(Color.white.opacity(0.18))
                )
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .help("Close lesson (Esc)")
    }

    private var stepCounterLabel: String {
        let currentDisplayIndex = viewModel.currentStepIndex + 1
        let totalStepCount = max(1, viewModel.totalStepCount)
        return "Step \(currentDisplayIndex)/\(totalStepCount)"
    }

    private var stepInstructionDisplayText: String {
        guard let instructionText = viewModel.currentStep?.instructionText,
              !instructionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return viewModel.currentStep?.title ?? ""
        }
        return instructionText
    }

    private var isAtFirstStep: Bool {
        viewModel.currentStepIndex <= 0
    }

    private var isAtLastStep: Bool {
        viewModel.currentStepIndex >= viewModel.totalStepCount - 1
    }
}

