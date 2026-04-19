//
//  OverlayWindow.swift
//  claude-cursor
//
//  System-wide transparent overlay window for the companion cursor (SVG + glow).
//  One OverlayWindow is created per screen so the cursor buddy
//  seamlessly follows the cursor across multiple monitors.
//

import AppKit
import AVFoundation
import SwiftUI

class OverlayWindow: NSWindow {
    init(screen: NSScreen) {
        // Create window covering entire screen
        super.init(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )

        // Make window transparent and non-interactive
        self.isOpaque = false
        self.backgroundColor = .clear
        self.level = .screenSaver  // Always on top, above submenus and popups
        self.ignoresMouseEvents = true  // Click-through
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        self.isReleasedWhenClosed = false
        self.hasShadow = false

        // Important: Allow the window to appear even when app is not active
        self.hidesOnDeactivate = false

        // Cover the entire screen
        self.setFrame(screen.frame, display: true)

        // Make sure it's on the right screen
        if let screenForWindow = NSScreen.screens.first(where: { $0.frame == screen.frame }) {
            self.setFrameOrigin(screenForWindow.frame.origin)
        }
    }

    // Prevent window from becoming key (no focus stealing)
    override var canBecomeKey: Bool {
        return false
    }

    override var canBecomeMain: Bool {
        return false
    }
}

// MARK: - Legacy triangle cursor (replaced by `Image("claudeCursor")`; kept for reference)
//
// Cursor-like triangle shape (equilateral)
// struct Triangle: Shape {
//     func path(in rect: CGRect) -> Path {
//         var path = Path()
//         let size = min(rect.width, rect.height)
//         let height = size * sqrt(3.0) / 2.0
//
//         // Top vertex
//         path.move(to: CGPoint(x: rect.midX, y: rect.midY - height / 1.5))
//         // Bottom left vertex
//         path.addLine(to: CGPoint(x: rect.midX - size / 2, y: rect.midY + height / 3))
//         // Bottom right vertex
//         path.addLine(to: CGPoint(x: rect.midX + size / 2, y: rect.midY + height / 3))
//         path.closeSubpath()
//         return path
//     }
// }

// PreferenceKey for tracking bubble size
struct SizePreferenceKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

struct NavigationBubbleSizePreferenceKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

/// The buddy's behavioral mode. Controls whether it follows the cursor,
/// is flying toward a detected UI element, or is pointing at an element.
enum BuddyNavigationMode {
    /// Default — buddy follows the mouse cursor with spring animation
    case followingCursor
    /// Buddy is animating toward a detected UI element location
    case navigatingToTarget
    /// Buddy has arrived at the target and is pointing at it with a speech bubble
    case pointingAtTarget
}

// SwiftUI view for the companion cursor (pixel SVG + glow).
// Each screen gets its own BlueCursorView. The view checks whether
// the cursor is currently on THIS screen and only shows the buddy
// triangle when it is. During voice interaction, the triangle is
// replaced by a waveform (listening), spinner (processing), or
// streaming text bubble (responding).
struct BlueCursorView: View {
    let screenFrame: CGRect
    let isFirstAppearance: Bool
    @ObservedObject var companionManager: CompanionManager

    @State private var cursorPosition: CGPoint
    @State private var isCursorOnThisScreen: Bool

    init(screenFrame: CGRect, isFirstAppearance: Bool, companionManager: CompanionManager) {
        self.screenFrame = screenFrame
        self.isFirstAppearance = isFirstAppearance
        self.companionManager = companionManager

        // Seed the cursor position from the current mouse location so the
        // buddy doesn't flash at (0,0) before onAppear fires.
        let mouseLocation = NSEvent.mouseLocation
        let localX = mouseLocation.x - screenFrame.origin.x
        let localY = screenFrame.height - (mouseLocation.y - screenFrame.origin.y)
        _cursorPosition = State(initialValue: CGPoint(x: localX + 35, y: localY + 25))
        _isCursorOnThisScreen = State(initialValue: screenFrame.contains(mouseLocation))
    }
    @State private var timer: Timer?
    @State private var welcomeText: String = ""
    @State private var showWelcome: Bool = true
    @State private var bubbleSize: CGSize = .zero
    @State private var bubbleOpacity: Double = 1.0
    @State private var cursorOpacity: Double = 0.0

    // MARK: - Buddy Navigation State

    /// The buddy's current behavioral mode (following cursor, navigating, or pointing).
    @State private var buddyNavigationMode: BuddyNavigationMode = .followingCursor

    /// The rotation angle of the triangle in degrees. Default is -35° (cursor-like).
    /// Changes to face the direction of travel when navigating to a target.
    @State private var triangleRotationDegrees: Double = -35.0

    /// Speech bubble text shown when pointing at a detected element.
    @State private var navigationBubbleText: String = ""
    @State private var navigationBubbleOpacity: Double = 0.0
    @State private var navigationBubbleSize: CGSize = .zero

    /// The cursor position at the moment navigation started, used to detect
    /// if the user moves the cursor enough to cancel the navigation.
    @State private var cursorPositionWhenNavigationStarted: CGPoint = .zero

    /// Timer driving the frame-by-frame bezier arc flight animation.
    /// Invalidated when the flight completes, is canceled, or the view disappears.
    @State private var navigationAnimationTimer: Timer?

    /// Scale factor applied to the buddy triangle during flight. Grows to ~1.3x
    /// at the midpoint of the arc and shrinks back to 1.0x on landing, creating
    /// an energetic "swooping" feel.
    @State private var buddyFlightScale: CGFloat = 1.0

    /// Scale factor for the navigation speech bubble's pop-in entrance.
    /// Starts at 0.5 and springs to 1.0 when the first character appears.
    @State private var navigationBubbleScale: CGFloat = 1.0

    /// True when the buddy is flying BACK to the cursor after pointing.
    /// Only during the return flight can cursor movement cancel the animation.
    @State private var isReturningToCursor: Bool = false

    // MARK: - Navigation Bubble Typewriter

    /// Streams the pointer-phrase text into the bubble one character at a
    /// time. Shared with the consent pill so both surfaces pop in with the
    /// exact same 30–60ms cadence.
    @State private var navigationBubbleTypewriter = CursorPillTypewriter()

    /// Consumer of the typewriter's `AsyncStream`. Cancelled on
    /// disappear / navigation-cancel / fly-back so late characters never
    /// mutate a reset bubble.
    @State private var navigationBubbleTypewriterConsumerTask: Task<Void, Never>?

    /// The 3-second "hold the bubble up so the user can read it" timer that
    /// runs after streaming completes. Held on @State so a cancellation can
    /// reach into it without knowing its identity inline.
    @State private var navigationBubbleHoldCompletionWorkItem: DispatchWorkItem?

    /// The 500ms fade-out timer that kicks off the fly-back to the cursor.
    /// Tracked so `cancelNavigationAndResumeFollowing` can stop it.
    @State private var navigationBubbleFadeOutWorkItem: DispatchWorkItem?

    // MARK: - Onboarding Video Layout

    private let onboardingVideoPlayerWidth: CGFloat = 330
    private let onboardingVideoPlayerHeight: CGFloat = 186

    private let fullWelcomeMessage = "hey! i'm claude cursor"

    /// Renders crisp pixel edges for the asset-catalog SVG cursor.
    private let companionCursorImageSize: CGFloat = 22

    private let navigationPointerPhrases = [
        "right here!",
        "this one!",
        "over here!",
        "click this!",
        "here it is!",
        "found it!"
    ]

    // MARK: - Lesson-Aware Cursor Color

    /// Terracotta companion color (matches `claudeCursor` SVG fill).
    private var cursorBuddyColor: Color {
        DS.Colors.overlayCursorBrand
    }

    var body: some View {
        ZStack {
            // Nearly transparent background (helps with compositing)
            Color.black.opacity(0.001)

            // Welcome speech bubble (first launch only)
            if isCursorOnThisScreen && showWelcome && !welcomeText.isEmpty {
                Text(welcomeText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(DS.Colors.overlayCursorBrand)
                            .shadow(color: DS.Colors.overlayCursorBrand.opacity(0.5), radius: 6, x: 0, y: 0)
                    )
                    .fixedSize()
                    .overlay(
                        GeometryReader { geo in
                            Color.clear
                                .preference(key: SizePreferenceKey.self, value: geo.size)
                        }
                    )
                    .opacity(bubbleOpacity)
                    .position(x: cursorPosition.x + 10 + (bubbleSize.width / 2), y: cursorPosition.y + 18)
                    .animation(.spring(response: 0.2, dampingFraction: 0.6, blendDuration: 0), value: cursorPosition)
                    .animation(.easeOut(duration: 0.5), value: bubbleOpacity)
                    .onPreferenceChange(SizePreferenceKey.self) { newSize in
                        bubbleSize = newSize
                    }
            }

            // Onboarding video — always in the view tree so opacity animation works
            // reliably. When no player exists or opacity is 0, nothing is visible.
            // allowsHitTesting(false) prevents it from intercepting clicks.
            OnboardingVideoPlayerView(player: companionManager.onboardingVideoPlayer)
                .frame(width: onboardingVideoPlayerWidth, height: onboardingVideoPlayerHeight)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .shadow(color: Color.black.opacity(0.4 * companionManager.onboardingVideoOpacity), radius: 12, x: 0, y: 6)
                .opacity(isCursorOnThisScreen ? companionManager.onboardingVideoOpacity : 0)
                .position(
                    x: cursorPosition.x + 10 + (onboardingVideoPlayerWidth / 2),
                    y: cursorPosition.y + 18 + (onboardingVideoPlayerHeight / 2)
                )
                .animation(.spring(response: 0.2, dampingFraction: 0.6, blendDuration: 0), value: cursorPosition)
                .animation(.easeInOut(duration: 2.0), value: companionManager.onboardingVideoOpacity)
                .allowsHitTesting(false)

            // Onboarding prompt — "press control + option and say hi" streamed after video ends
            if isCursorOnThisScreen && companionManager.showOnboardingPrompt && !companionManager.onboardingPromptText.isEmpty {
                Text(companionManager.onboardingPromptText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(DS.Colors.overlayCursorBrand)
                            .shadow(color: DS.Colors.overlayCursorBrand.opacity(0.5), radius: 6, x: 0, y: 0)
                    )
                    .fixedSize()
                    .overlay(
                        GeometryReader { geo in
                            Color.clear
                                .preference(key: SizePreferenceKey.self, value: geo.size)
                        }
                    )
                    .opacity(companionManager.onboardingPromptOpacity)
                    .position(x: cursorPosition.x + 10 + (bubbleSize.width / 2), y: cursorPosition.y + 18)
                    .animation(.spring(response: 0.2, dampingFraction: 0.6, blendDuration: 0), value: cursorPosition)
                    .animation(.easeOut(duration: 0.4), value: companionManager.onboardingPromptOpacity)
                    .onPreferenceChange(SizePreferenceKey.self) { newSize in
                        bubbleSize = newSize
                    }
            }

            // Navigation pointer bubble — shown when buddy arrives at a detected element.
            // Pops in with a scale-bounce (0.5x → 1.0x spring) and a bright initial
            // glow that settles, creating a "materializing" effect. Styling lives
            // in the shared `CursorPillBubble`; the scale value drives both the
            // visual transform (via `.scaleEffect`) and the dynamic shadow formula
            // (inside the bubble), so the glow fades as the pill settles.
            if buddyNavigationMode == .pointingAtTarget && !navigationBubbleText.isEmpty {
                CursorPillBubble(
                    text: navigationBubbleText,
                    scale: navigationBubbleScale,
                    opacity: navigationBubbleOpacity,
                    sizing: .intrinsic
                )
                .overlay(
                    GeometryReader { geo in
                        Color.clear
                            .preference(key: NavigationBubbleSizePreferenceKey.self, value: geo.size)
                    }
                )
                .scaleEffect(navigationBubbleScale)
                .position(x: cursorPosition.x + 10 + (navigationBubbleSize.width / 2), y: cursorPosition.y + 18)
                .animation(.spring(response: 0.2, dampingFraction: 0.6, blendDuration: 0), value: cursorPosition)
                .animation(.spring(response: 0.4, dampingFraction: 0.6), value: navigationBubbleScale)
                .animation(.easeOut(duration: 0.5), value: navigationBubbleOpacity)
                .onPreferenceChange(NavigationBubbleSizePreferenceKey.self) { newSize in
                    navigationBubbleSize = newSize
                }
            }

            // Cursor buddy — SVG from asset catalog; idle or while TTS is playing.
            //
            // All three states (image, waveform, spinner) stay in the view tree
            // permanently and cross-fade via opacity so SwiftUI doesn't remove/re-insert
            // them (which caused a visible cursor "pop").
            //
            // During cursor following: fast spring animation for snappy tracking.
            // During navigation: NO implicit animation — the frame-by-frame bezier
            // timer controls position directly at 60fps for a smooth arc flight.
            Image("claudeCursor")
                .resizable()
                .interpolation(.none)
                .antialiased(false)
                .frame(width: companionCursorImageSize, height: companionCursorImageSize)
                .rotationEffect(.degrees(triangleRotationDegrees))
                .shadow(color: cursorBuddyColor, radius: 8 + (buddyFlightScale - 1.0) * 20, x: 0, y: 0)
                .scaleEffect(buddyFlightScale)
                .opacity(
                    buddyIsVisibleOnThisScreen && (companionManager.voiceState == .idle
                            || companionManager.voiceState == .responding
                            || (companionManager.voiceState == .processing
                                && !companionManager.activePointingTargets.isEmpty))
                        ? cursorOpacity
                        : 0
                )
                .position(cursorPosition)
                .animation(
                    buddyNavigationMode == .followingCursor
                        ? .spring(response: 0.2, dampingFraction: 0.6, blendDuration: 0)
                        : nil,
                    value: cursorPosition
                )
                .animation(.easeIn(duration: 0.25), value: companionManager.voiceState)
                .animation(
                    buddyNavigationMode == .navigatingToTarget ? nil : .easeInOut(duration: 0.3),
                    value: triangleRotationDegrees
                )

            // Blue waveform — replaces the triangle while listening
            BlueCursorWaveformView(audioPowerLevel: companionManager.currentAudioPowerLevel)
                .opacity(buddyIsVisibleOnThisScreen && companionManager.voiceState == .listening ? cursorOpacity : 0)
                .position(cursorPosition)
                .animation(.spring(response: 0.2, dampingFraction: 0.6, blendDuration: 0), value: cursorPosition)
                .animation(.easeIn(duration: 0.15), value: companionManager.voiceState)

            // Blue spinner — shown while the AI is working and there is not yet
            // a pointing target (once coordinates land, the triangle stays up
            // through TTS download so the buddy does not "go idle" early).
            BlueCursorSpinnerView()
                .opacity(
                    buddyIsVisibleOnThisScreen
                        && companionManager.voiceState == .processing
                        && companionManager.activePointingTargets.isEmpty
                        && companionManager.activeExplainerCursorGroup == nil
                        ? cursorOpacity
                        : 0
                )
                .position(cursorPosition)
                .animation(.spring(response: 0.2, dampingFraction: 0.6, blendDuration: 0), value: cursorPosition)
                .animation(.easeIn(duration: 0.15), value: companionManager.voiceState)

            if buddyIsVisibleOnThisScreen,
               companionManager.voiceState == .processing,
               !companionManager.computerUseAutomationStatusLine.isEmpty {
                Text(companionManager.computerUseAutomationStatusLine)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white.opacity(0.92))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.black.opacity(0.55))
                    )
                    .fixedSize()
                    .position(x: cursorPosition.x + 10, y: cursorPosition.y + 52)
                    .animation(.spring(response: 0.2, dampingFraction: 0.65), value: cursorPosition)
            }

            // Secondary pointing targets — stationary markers for every target
            // beyond the primary one (which is handled by the flight-animation
            // state machine above). Each secondary target gets its own Triangle
            // + label pill pinned at its `screenLocation`. Targets on other
            // screens are filtered out so each overlay only renders its own
            // screen's markers.
            ForEach(secondaryPointingTargetsOnThisScreen) { pointingTarget in
                PointingTargetMarker(
                    pointingTarget: pointingTarget,
                    markerPositionInSwiftUICoordinates: convertScreenPointToSwiftUICoordinates(
                        pointingTarget.screenLocation
                    ),
                    staggerIndex: indexAmongSecondaryTargets(pointingTarget)
                )
            }

            // Multi-cursor explainer overlay. Sub-cursors spawn from the
            // main cursor and fly to their targets simultaneously.
            if let explainerGroup = companionManager.activeExplainerCursorGroup {
                let elementsOnThisScreen = explainerGroup.elements.filter { element in
                    screenFrame.contains(CGPoint(
                        x: element.screenLocation.x,
                        y: element.screenLocation.y
                    ))
                }
                ForEach(Array(elementsOnThisScreen.enumerated()), id: \.element.id) { index, element in
                    ExplainerCursorMarker(
                        element: element,
                        mainCursorPositionInSwiftUI: cursorPosition,
                        targetPositionInSwiftUI: convertScreenPointToSwiftUICoordinates(
                            element.screenLocation
                        ),
                        overlayBoundsInSwiftUI: CGRect(
                            origin: .zero,
                            size: CGSize(width: screenFrame.width, height: screenFrame.height)
                        ),
                        staggerIndex: index,
                        isReturningToMain: companionManager.isExplainerGroupReturning
                    )
                }
            }
        }
        .frame(width: screenFrame.width, height: screenFrame.height)
        .ignoresSafeArea()
        .onAppear {
            // Set initial cursor position immediately before starting animation
            let mouseLocation = NSEvent.mouseLocation
            isCursorOnThisScreen = screenFrame.contains(mouseLocation)

            let swiftUIPosition = convertScreenPointToSwiftUICoordinates(mouseLocation)
            self.cursorPosition = CGPoint(x: swiftUIPosition.x + 35, y: swiftUIPosition.y + 25)

            startTrackingCursor()

            // Only show welcome message on first appearance (app start)
            // and only if the cursor starts on this screen
            if isFirstAppearance && isCursorOnThisScreen {
                withAnimation(.easeIn(duration: 2.0)) {
                    self.cursorOpacity = 1.0
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    self.bubbleOpacity = 0.0
                    startWelcomeAnimation()
                }
            } else {
                self.cursorOpacity = 1.0
            }
        }
        .onDisappear {
            timer?.invalidate()
            navigationAnimationTimer?.invalidate()
            cancelNavigationBubbleTypewriterAndTimers()
            companionManager.tearDownOnboardingVideo()
        }
        .onChange(of: companionManager.detectedElementScreenLocation) { newLocation in
            // When a UI element location is detected, navigate the buddy to
            // that position so it points at the element.
            guard let screenLocation = newLocation,
                  let displayFrame = companionManager.detectedElementDisplayFrame else {
                return
            }

            // Only navigate if the target is on THIS screen
            guard screenFrame.contains(CGPoint(x: displayFrame.midX, y: displayFrame.midY))
                  || displayFrame == screenFrame else {
                return
            }

            startNavigatingToElement(screenLocation: screenLocation)
        }
    }

    /// Whether the buddy triangle should be visible on this screen.
    /// True when cursor is on this screen during normal following, or
    /// when navigating/pointing at a target on this screen. When another
    /// screen is navigating (detectedElementScreenLocation is set but this
    /// screen isn't the one animating), hide the cursor so only one buddy
    /// is ever visible at a time.
    private var buddyIsVisibleOnThisScreen: Bool {
        switch buddyNavigationMode {
        case .followingCursor:
            // If another screen's BlueCursorView is navigating to an element,
            // hide the cursor on this screen to prevent a duplicate buddy
            if companionManager.detectedElementScreenLocation != nil {
                return false
            }
            return isCursorOnThisScreen
        case .navigatingToTarget, .pointingAtTarget:
            return true
        }
    }

    // MARK: - Multi-Target Pointing

    /// Pointing targets (beyond the primary one) that resolve to this screen.
    /// The primary target drives the existing flight-animation state machine
    /// via the back-compat scalar accessors; everything after index 0 is
    /// rendered as a stationary `PointingTargetMarker` instead.
    private var secondaryPointingTargetsOnThisScreen: [CompanionManager.PointingTarget] {
        let allTargets = companionManager.activePointingTargets
        guard let primaryTarget = allTargets.first,
              allTargets.count > 1 else { return [] }
        return Array(allTargets.dropFirst()).filter { target in
            if secondaryPointingTargetIsRedundantWithPrimary(
                target,
                primaryTarget: primaryTarget
            ) {
                return false
            }
            let midpointOfTargetDisplay = CGPoint(
                x: target.displayFrame.midX,
                y: target.displayFrame.midY
            )
            return screenFrame.contains(midpointOfTargetDisplay)
                || target.displayFrame == screenFrame
        }
    }

    /// Hides a duplicate label stacked under the primary bubble when the model
    /// emitted two near-identical `point_at_element` calls.
    private func secondaryPointingTargetIsRedundantWithPrimary(
        _ secondaryTarget: CompanionManager.PointingTarget,
        primaryTarget: CompanionManager.PointingTarget
    ) -> Bool {
        let distanceThresholdPoints: CGFloat = 72
        let thresholdSquared = distanceThresholdPoints * distanceThresholdPoints
        guard !secondaryTarget.labelText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              secondaryTarget.labelText.caseInsensitiveCompare(primaryTarget.labelText)
                == .orderedSame else {
            return false
        }
        let dx = secondaryTarget.screenLocation.x - primaryTarget.screenLocation.x
        let dy = secondaryTarget.screenLocation.y - primaryTarget.screenLocation.y
        return (dx * dx + dy * dy) < thresholdSquared
    }

    /// Index of `target` within the secondary-targets list, used to stagger
    /// the pop-in animation so multiple markers don't all appear at once.
    private func indexAmongSecondaryTargets(
        _ target: CompanionManager.PointingTarget
    ) -> Int {
        secondaryPointingTargetsOnThisScreen.firstIndex(of: target) ?? 0
    }

    // MARK: - Cursor Tracking

    private func startTrackingCursor() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.016, repeats: true) { _ in
            let mouseLocation = NSEvent.mouseLocation
            self.isCursorOnThisScreen = self.screenFrame.contains(mouseLocation)

            // During forward flight or pointing, the buddy is NOT interrupted by
            // mouse movement — it completes its full animation and return flight.
            // Only during the RETURN flight do we allow cursor movement to cancel
            // (so the buddy snaps to following if the user moves while it's flying back).
            if self.buddyNavigationMode == .navigatingToTarget && self.isReturningToCursor {
                let currentMouseInSwiftUI = self.convertScreenPointToSwiftUICoordinates(mouseLocation)
                let distanceFromNavigationStart = hypot(
                    currentMouseInSwiftUI.x - self.cursorPositionWhenNavigationStarted.x,
                    currentMouseInSwiftUI.y - self.cursorPositionWhenNavigationStarted.y
                )
                if distanceFromNavigationStart > 100 {
                    cancelNavigationAndResumeFollowing()
                }
                return
            }

            // During forward navigation or pointing, just skip cursor tracking
            if self.buddyNavigationMode != .followingCursor {
                return
            }

            // Normal cursor following
            let swiftUIPosition = self.convertScreenPointToSwiftUICoordinates(mouseLocation)
            let buddyX = swiftUIPosition.x + 35
            let buddyY = swiftUIPosition.y + 25
            self.cursorPosition = CGPoint(x: buddyX, y: buddyY)
        }
    }

    /// Converts a macOS screen point (AppKit, bottom-left origin) to SwiftUI
    /// coordinates (top-left origin) relative to this screen's overlay window.
    private func convertScreenPointToSwiftUICoordinates(_ screenPoint: CGPoint) -> CGPoint {
        let x = screenPoint.x - screenFrame.origin.x
        let y = (screenFrame.origin.y + screenFrame.height) - screenPoint.y
        return CGPoint(x: x, y: y)
    }

    // MARK: - Element Navigation

    /// Starts animating the buddy toward a detected UI element location.
    private func startNavigatingToElement(screenLocation: CGPoint) {
        // Don't interrupt welcome animation
        guard !showWelcome || welcomeText.isEmpty else { return }

        // Convert the AppKit screen location to SwiftUI coordinates for this screen
        let targetInSwiftUI = convertScreenPointToSwiftUICoordinates(screenLocation)

        // Offset the target so the buddy sits beside the element rather than
        // directly on top of it — 8px to the right, 12px below.
        let offsetTarget = CGPoint(
            x: targetInSwiftUI.x + 8,
            y: targetInSwiftUI.y + 12
        )

        // Clamp target to screen bounds with padding
        let clampedTarget = CGPoint(
            x: max(20, min(offsetTarget.x, screenFrame.width - 20)),
            y: max(20, min(offsetTarget.y, screenFrame.height - 20))
        )

        // Record the current cursor position so we can detect if the user
        // moves the mouse enough to cancel the return flight
        let mouseLocation = NSEvent.mouseLocation
        cursorPositionWhenNavigationStarted = convertScreenPointToSwiftUICoordinates(mouseLocation)

        // Enter navigation mode — stop cursor following
        buddyNavigationMode = .navigatingToTarget
        isReturningToCursor = false

        animateBezierFlightArc(to: clampedTarget) {
            guard self.buddyNavigationMode == .navigatingToTarget else { return }
            self.startPointingAtElement()
        }
    }

    /// Animates the buddy along a quadratic bezier arc from its current position
    /// to the specified destination. The triangle rotates to face its direction
    /// of travel (tangent to the curve) each frame, scales up at the midpoint
    /// for a "swooping" feel, and the glow intensifies during flight.
    private func animateBezierFlightArc(
        to destination: CGPoint,
        onComplete: @escaping () -> Void
    ) {
        navigationAnimationTimer?.invalidate()

        let startPosition = cursorPosition
        let endPosition = destination

        let deltaX = endPosition.x - startPosition.x
        let deltaY = endPosition.y - startPosition.y
        let distance = hypot(deltaX, deltaY)

        // Flight duration scales with distance: short hops are quick, long
        // flights are more dramatic. Clamped to 0.6s–1.4s.
        let flightDurationSeconds = min(max(distance / 800.0, 0.6), 1.4)
        let frameInterval: Double = 1.0 / 60.0
        let totalFrames = Int(flightDurationSeconds / frameInterval)
        var currentFrame = 0

        // Control point for the quadratic bezier arc. Offset the midpoint
        // upward (negative Y in SwiftUI) so the buddy flies in a parabolic arc.
        let midPoint = CGPoint(
            x: (startPosition.x + endPosition.x) / 2.0,
            y: (startPosition.y + endPosition.y) / 2.0
        )
        let arcHeight = min(distance * 0.2, 80.0)
        let controlPoint = CGPoint(x: midPoint.x, y: midPoint.y - arcHeight)

        navigationAnimationTimer = Timer.scheduledTimer(withTimeInterval: frameInterval, repeats: true) { _ in
            currentFrame += 1

            if currentFrame > totalFrames {
                self.navigationAnimationTimer?.invalidate()
                self.navigationAnimationTimer = nil
                self.cursorPosition = endPosition
                self.buddyFlightScale = 1.0
                onComplete()
                return
            }

            // Linear progress 0→1 over the flight duration
            let linearProgress = Double(currentFrame) / Double(totalFrames)

            // Smoothstep easeInOut: 3t² - 2t³ (Hermite interpolation)
            let t = linearProgress * linearProgress * (3.0 - 2.0 * linearProgress)

            // Quadratic bezier: B(t) = (1-t)²·P0 + 2(1-t)t·P1 + t²·P2
            let oneMinusT = 1.0 - t
            let bezierX = oneMinusT * oneMinusT * startPosition.x
                        + 2.0 * oneMinusT * t * controlPoint.x
                        + t * t * endPosition.x
            let bezierY = oneMinusT * oneMinusT * startPosition.y
                        + 2.0 * oneMinusT * t * controlPoint.y
                        + t * t * endPosition.y

            self.cursorPosition = CGPoint(x: bezierX, y: bezierY)

            // Rotation: face the direction of travel by computing the tangent
            // to the bezier curve. B'(t) = 2(1-t)(P1-P0) + 2t(P2-P1)
            let tangentX = 2.0 * oneMinusT * (controlPoint.x - startPosition.x)
                         + 2.0 * t * (endPosition.x - controlPoint.x)
            let tangentY = 2.0 * oneMinusT * (controlPoint.y - startPosition.y)
                         + 2.0 * t * (endPosition.y - controlPoint.y)
            // +90° offset because the triangle's "tip" points up at 0° rotation,
            // and atan2 returns 0° for rightward movement
            self.triangleRotationDegrees = atan2(tangentY, tangentX) * (180.0 / .pi) + 90.0

            // Scale pulse: sin curve peaks at midpoint of the flight.
            // Buddy grows to ~1.3x at the apex, then shrinks back to 1.0x on landing.
            let scalePulse = sin(linearProgress * .pi)
            self.buddyFlightScale = 1.0 + scalePulse * 0.3
        }
    }

    /// Transitions to pointing mode — shows a speech bubble with a bouncy
    /// scale-in entrance and variable-speed character streaming.
    private func startPointingAtElement() {
        buddyNavigationMode = .pointingAtTarget
        companionManager.signalPrimaryPointingForwardFlightArrived()

        // Rotate back to default pointer angle now that we've arrived
        triangleRotationDegrees = -35.0

        // Reset navigation bubble state — start small for the scale-bounce entrance
        navigationBubbleText = ""
        navigationBubbleOpacity = 1.0
        navigationBubbleSize = .zero
        navigationBubbleScale = 0.5

        // Use custom bubble text from the companion manager (e.g. onboarding demo)
        // if available, otherwise fall back to a random pointer phrase
        let pointerPhrase = companionManager.detectedElementBubbleText
            ?? navigationPointerPhrases.randomElement()
            ?? "right here!"

        streamNavigationBubblePhrase(pointerPhrase)
    }

    /// Streams `phrase` into the navigation bubble via the shared
    /// `CursorPillTypewriter`. The first `.character` event pops the bubble
    /// from scale 0.5 → 1.0, subsequent events append one character at a
    /// time, and `.completed` schedules a 3-second read-hold before the
    /// fly-back. Any prior consumer task and pending hold / fade timers are
    /// cancelled first so a second pointing session always starts from a
    /// clean slate.
    private func streamNavigationBubblePhrase(_ phrase: String) {
        navigationBubbleTypewriterConsumerTask?.cancel()
        navigationBubbleTypewriterConsumerTask = nil
        navigationBubbleHoldCompletionWorkItem?.cancel()
        navigationBubbleHoldCompletionWorkItem = nil
        navigationBubbleFadeOutWorkItem?.cancel()
        navigationBubbleFadeOutWorkItem = nil

        let eventStream = navigationBubbleTypewriter.stream(text: phrase)
        navigationBubbleTypewriterConsumerTask = Task { @MainActor in
            var isFirstCharacter = true
            for await event in eventStream {
                switch event {
                case .character(let nextCharacter):
                    self.navigationBubbleText.append(nextCharacter)
                    if isFirstCharacter {
                        self.navigationBubbleScale = 1.0
                        isFirstCharacter = false
                    }
                case .completed:
                    self.scheduleNavigationBubbleHoldThenFlyBack()
                case .cancelled:
                    return
                }
            }
        }
    }

    /// Runs the 3-second read-hold, 500ms opacity fade, then fly-back
    /// sequence after the pointer phrase finishes streaming. Each phase is
    /// a `DispatchWorkItem` held on state so `cancelNavigationAndResumeFollowing`
    /// can short-circuit the sequence if the user moves the cursor mid-hold.
    private func scheduleNavigationBubbleHoldThenFlyBack() {
        let holdWorkItem = DispatchWorkItem {
            guard self.buddyNavigationMode == .pointingAtTarget else { return }
            self.navigationBubbleOpacity = 0.0

            let fadeWorkItem = DispatchWorkItem {
                guard self.buddyNavigationMode == .pointingAtTarget else { return }
                self.startFlyingBackToCursor()
            }
            self.navigationBubbleFadeOutWorkItem = fadeWorkItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: fadeWorkItem)
        }
        navigationBubbleHoldCompletionWorkItem = holdWorkItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0, execute: holdWorkItem)
    }

    /// Flies the buddy back to the current cursor position after pointing is done.
    private func startFlyingBackToCursor() {
        let mouseLocation = NSEvent.mouseLocation
        let cursorInSwiftUI = convertScreenPointToSwiftUICoordinates(mouseLocation)
        let cursorWithTrackingOffset = CGPoint(x: cursorInSwiftUI.x + 35, y: cursorInSwiftUI.y + 25)

        cursorPositionWhenNavigationStarted = cursorInSwiftUI

        buddyNavigationMode = .navigatingToTarget
        isReturningToCursor = true

        animateBezierFlightArc(to: cursorWithTrackingOffset) {
            self.finishNavigationAndResumeFollowing()
        }
    }

    /// Cancels an in-progress navigation because the user moved the cursor.
    private func cancelNavigationAndResumeFollowing() {
        navigationAnimationTimer?.invalidate()
        navigationAnimationTimer = nil
        cancelNavigationBubbleTypewriterAndTimers()
        navigationBubbleText = ""
        navigationBubbleOpacity = 0.0
        navigationBubbleScale = 1.0
        buddyFlightScale = 1.0
        finishNavigationAndResumeFollowing()
    }

    /// Returns the buddy to normal cursor-following mode after navigation completes.
    private func finishNavigationAndResumeFollowing() {
        navigationAnimationTimer?.invalidate()
        navigationAnimationTimer = nil
        cancelNavigationBubbleTypewriterAndTimers()
        buddyNavigationMode = .followingCursor
        isReturningToCursor = false
        triangleRotationDegrees = -35.0
        buddyFlightScale = 1.0
        navigationBubbleText = ""
        navigationBubbleOpacity = 0.0
        navigationBubbleScale = 1.0
        companionManager.clearDetectedElementLocation()
    }

    /// Cancels the typewriter stream and any pending hold / fade timers so
    /// a torn-down or cancelled navigation never races a late character or
    /// a stale fly-back trigger against a subsequent pointing session.
    private func cancelNavigationBubbleTypewriterAndTimers() {
        navigationBubbleTypewriter.cancelCurrentStream()
        navigationBubbleTypewriterConsumerTask?.cancel()
        navigationBubbleTypewriterConsumerTask = nil
        navigationBubbleHoldCompletionWorkItem?.cancel()
        navigationBubbleHoldCompletionWorkItem = nil
        navigationBubbleFadeOutWorkItem?.cancel()
        navigationBubbleFadeOutWorkItem = nil
    }

    // MARK: - Welcome Animation

    private func startWelcomeAnimation() {
        withAnimation(.easeIn(duration: 0.4)) {
            self.bubbleOpacity = 1.0
        }

        var currentIndex = 0
        Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { timer in
            guard currentIndex < self.fullWelcomeMessage.count else {
                timer.invalidate()
                // Hold the text for 2 seconds, then fade it out
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    self.bubbleOpacity = 0.0
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                    self.showWelcome = false
                    // Start the onboarding video right after the welcome text disappears
                    self.companionManager.setupOnboardingVideo()
                }
                return
            }

            let index = self.fullWelcomeMessage.index(self.fullWelcomeMessage.startIndex, offsetBy: currentIndex)
            self.welcomeText.append(self.fullWelcomeMessage[index])
            currentIndex += 1
        }
    }
}

// MARK: - Pointing Target Marker

/// A stationary cursor image + label pill pinned at a detected UI element.
/// Used for *secondary* pointing targets when Claude emits multiple
/// `[POINT:...]` tags in one response — the primary target continues to
/// drive the buddy's flight animation, while every additional target is
/// rendered by one of these markers.
///
/// Each marker owns a small scale-in pop animation so when several targets
/// arrive together they appear in staggered sequence rather than all
/// blinking on at once.
private struct PointingTargetMarker: View {
    let pointingTarget: CompanionManager.PointingTarget
    let markerPositionInSwiftUICoordinates: CGPoint
    let staggerIndex: Int

    @State private var markerScale: CGFloat = 0.5
    @State private var markerOpacity: Double = 0.0

    /// Horizontal offset from the cursor glyph to the label pill's anchor.
    /// Matches the primary buddy's bubble offset for visual consistency.
    private let labelPillOffsetX: CGFloat = 10
    private let labelPillOffsetY: CGFloat = 18

    private let markerCursorImageSize: CGFloat = 22

    /// Per-target stagger so multiple markers don't all pop in on the same
    /// frame. 100ms between each based on index (see plan Phase 9B).
    private var staggerDelaySeconds: Double {
        Double(staggerIndex) * 0.1
    }

    var body: some View {
        ZStack {
            // Stationary cursor at the target's screen location. Rotated to match
            // the primary buddy's default pointer angle.
            Image("claudeCursor")
                .resizable()
                .interpolation(.none)
                .antialiased(false)
                .frame(width: markerCursorImageSize, height: markerCursorImageSize)
                .rotationEffect(.degrees(-35.0))
                .shadow(color: DS.Colors.overlayCursorBrand, radius: 8, x: 0, y: 0)
                .scaleEffect(markerScale)
                .opacity(markerOpacity)
                .position(markerPositionInSwiftUICoordinates)

            // Label pill sits to the upper-right of the cursor, matching
            // where the primary buddy renders its speech bubble.
            if !pointingTarget.labelText.isEmpty {
                Text(pointingTarget.labelText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(DS.Colors.overlayCursorBrand)
                            .shadow(
                                color: DS.Colors.overlayCursorBrand.opacity(0.5),
                                radius: 6,
                                x: 0,
                                y: 0
                            )
                    )
                    .fixedSize()
                    .scaleEffect(markerScale)
                    .opacity(markerOpacity)
                    .position(
                        x: markerPositionInSwiftUICoordinates.x + labelPillOffsetX + 40,
                        y: markerPositionInSwiftUICoordinates.y + labelPillOffsetY
                    )
            }
        }
        .allowsHitTesting(false)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + staggerDelaySeconds) {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.6)) {
                    markerScale = 1.0
                    markerOpacity = 1.0
                }
            }
        }
    }
}

// MARK: - Multi-Cursor Explainer Marker

/// A single sub-cursor in the `explain_screen_elements` overlay. Unlike
/// `PointingTargetMarker`, each explainer cursor has its own color, a
/// two-line label (name + description), and animates from the main
/// cursor's position to its target (then back when dismissed).
private struct ExplainerCursorMarker: View {
    let element: CompanionManager.ExplainerElement
    let mainCursorPositionInSwiftUI: CGPoint
    let targetPositionInSwiftUI: CGPoint
    /// Local SwiftUI bounds for this overlay (origin 0,0 size = screen).
    let overlayBoundsInSwiftUI: CGRect
    let staggerIndex: Int
    let isReturningToMain: Bool

    @State private var hasArrivedAtTarget: Bool = false
    @State private var markerScale: CGFloat = 0.3
    @State private var markerOpacity: Double = 0.0

    private let cursorImageSize: CGFloat = 20
    private let spawnStaggerSeconds: Double = 0.12
    private let returnStaggerSeconds: Double = 0.08

    private var currentPosition: CGPoint {
        if isReturningToMain {
            return mainCursorPositionInSwiftUI
        }
        return hasArrivedAtTarget ? targetPositionInSwiftUI : mainCursorPositionInSwiftUI
    }

    /// Spread pills horizontally and vertically so stacked targets do not overlap labels; nudge away from screen edges.
    private var pillAnchorOffset: CGPoint {
        let angle = (Double(staggerIndex) * 2.3) - 2.85
        let radius: CGFloat = 26 + CGFloat(min(staggerIndex, 5)) * 5
        var offsetX = CGFloat(cos(angle)) * radius + CGFloat(staggerIndex - 3) * 10
        let offsetY = -36 - CGFloat(min(staggerIndex, 6)) * 5

        let pillReserveX: CGFloat = 120
        let proposedX = currentPosition.x + offsetX
        if proposedX < overlayBoundsInSwiftUI.minX + pillReserveX {
            offsetX += (overlayBoundsInSwiftUI.minX + pillReserveX) - proposedX
        } else if proposedX > overlayBoundsInSwiftUI.maxX - pillReserveX {
            offsetX -= proposedX - (overlayBoundsInSwiftUI.maxX - pillReserveX)
        }

        let pillReserveTop: CGFloat = 44
        var adjustedOffsetY = offsetY
        let proposedY = currentPosition.y + adjustedOffsetY
        if proposedY < overlayBoundsInSwiftUI.minY + pillReserveTop {
            adjustedOffsetY += (overlayBoundsInSwiftUI.minY + pillReserveTop) - proposedY
        }

        return CGPoint(x: offsetX, y: adjustedOffsetY)
    }

    /// Cursor asset points roughly up-left by default; rotate so the tip aims at the explainer target.
    private var cursorRotationTowardTargetDegrees: Double {
        let dx = targetPositionInSwiftUI.x - currentPosition.x
        let dy = targetPositionInSwiftUI.y - currentPosition.y
        guard abs(dx) + abs(dy) > 2 else { return -35 }
        let radians = atan2(Double(dy), Double(dx))
        return radians * 180 / .pi - 55
    }

    var body: some View {
        ZStack {
            if !element.labelText.isEmpty {
                let pillCenter = CGPoint(
                    x: currentPosition.x + pillAnchorOffset.x,
                    y: currentPosition.y + pillAnchorOffset.y
                )
                let estimatedPillHalfHeight: CGFloat = 28

                VStack(alignment: .leading, spacing: 2) {
                    Text(element.labelText)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white)
                    if !element.descriptionText.isEmpty {
                        Text(element.descriptionText)
                            .font(.system(size: 10, weight: .regular))
                            .foregroundColor(.white.opacity(0.85))
                            .lineLimit(2)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(element.assignedColor.opacity(0.92))
                        .shadow(
                            color: element.assignedColor.opacity(0.4),
                            radius: 6, x: 0, y: 2
                        )
                )
                .fixedSize()
                .scaleEffect(markerScale)
                .opacity(markerOpacity)
                .position(x: pillCenter.x, y: pillCenter.y)

                Path { path in
                    path.move(to: CGPoint(x: pillCenter.x, y: pillCenter.y + estimatedPillHalfHeight))
                    path.addLine(to: currentPosition)
                }
                .stroke(element.assignedColor.opacity(0.55), lineWidth: 1.5)
                .opacity(markerOpacity * 0.95)
            }

            Image("claudeCursor")
                .resizable()
                .interpolation(.none)
                .antialiased(false)
                .frame(width: cursorImageSize, height: cursorImageSize)
                .rotationEffect(.degrees(cursorRotationTowardTargetDegrees))
                .colorMultiply(element.assignedColor)
                .shadow(color: element.assignedColor.opacity(0.7), radius: 8, x: 0, y: 0)
                .scaleEffect(markerScale)
                .opacity(markerOpacity)
                .position(currentPosition)
        }
        .allowsHitTesting(false)
        .onAppear {
            let delay = Double(staggerIndex) * spawnStaggerSeconds
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) {
                    hasArrivedAtTarget = true
                    markerScale = 1.0
                    markerOpacity = 1.0
                }
            }
        }
        .onChange(of: isReturningToMain) { returning in
            guard returning else { return }
            let delay = Double(staggerIndex) * returnStaggerSeconds
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                    markerScale = 0.3
                    markerOpacity = 0.0
                }
            }
        }
        .animation(.spring(response: 0.5, dampingFraction: 0.7), value: currentPosition)
    }
}

// MARK: - Companion Cursor Waveform

/// A small waveform that replaces the cursor image while
/// the user is holding the push-to-talk shortcut and speaking.
private struct BlueCursorWaveformView: View {
    let audioPowerLevel: CGFloat

    private let barCount = 5
    private let listeningBarProfile: [CGFloat] = [0.4, 0.7, 1.0, 0.7, 0.4]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 36.0)) { timelineContext in
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<barCount, id: \.self) { barIndex in
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(DS.Colors.overlayCursorBrand)
                        .frame(
                            width: 2,
                            height: barHeight(
                                for: barIndex,
                                timelineDate: timelineContext.date
                            )
                        )
                }
            }
            .shadow(color: DS.Colors.overlayCursorBrand.opacity(0.6), radius: 6, x: 0, y: 0)
            .animation(.linear(duration: 0.08), value: audioPowerLevel)
        }
    }

    private func barHeight(for barIndex: Int, timelineDate: Date) -> CGFloat {
        let animationPhase = CGFloat(timelineDate.timeIntervalSinceReferenceDate * 3.6) + CGFloat(barIndex) * 0.35
        let normalizedAudioPowerLevel = max(audioPowerLevel - 0.008, 0)
        let easedAudioPowerLevel = pow(min(normalizedAudioPowerLevel * 2.85, 1), 0.76)
        let reactiveHeight = easedAudioPowerLevel * 10 * listeningBarProfile[barIndex]
        let idlePulse = (sin(animationPhase) + 1) / 2 * 1.5
        return 3 + reactiveHeight + idlePulse
    }
}

// MARK: - Companion Cursor Spinner

/// A small spinning indicator that replaces the cursor image
/// while the AI is processing a voice input.
private struct BlueCursorSpinnerView: View {
    @State private var isSpinning = false

    var body: some View {
        Circle()
            .trim(from: 0.15, to: 0.85)
            .stroke(
                AngularGradient(
                    colors: [
                        DS.Colors.overlayCursorBrand.opacity(0.0),
                        DS.Colors.overlayCursorBrand
                    ],
                    center: .center
                ),
                style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
            )
            .frame(width: 14, height: 14)
            .rotationEffect(.degrees(isSpinning ? 360 : 0))
            .shadow(color: DS.Colors.overlayCursorBrand.opacity(0.6), radius: 6, x: 0, y: 0)
            .onAppear {
                withAnimation(.linear(duration: 0.8).repeatForever(autoreverses: false)) {
                    isSpinning = true
                }
            }
    }
}

// Manager for overlay windows — creates one per screen so the cursor
// buddy seamlessly follows the cursor across multiple monitors.
@MainActor
class OverlayWindowManager {
    private var overlayWindows: [OverlayWindow] = []
    var hasShownOverlayBefore = false

    func showOverlay(onScreens screens: [NSScreen], companionManager: CompanionManager) {
        // Hide any existing overlays
        hideOverlay()

        // Track if this is the first time showing overlay (welcome message)
        let isFirstAppearance = !hasShownOverlayBefore
        hasShownOverlayBefore = true

        // Create one overlay window per screen
        for screen in screens {
            let window = OverlayWindow(screen: screen)

            let contentView = BlueCursorView(
                screenFrame: screen.frame,
                isFirstAppearance: isFirstAppearance,
                companionManager: companionManager
            )

            let hostingView = NSHostingView(rootView: contentView)
            hostingView.frame = screen.frame
            window.contentView = hostingView

            overlayWindows.append(window)
            window.orderFrontRegardless()
        }
    }

    func hideOverlay() {
        for window in overlayWindows {
            window.orderOut(nil)
            window.contentView = nil
        }
        overlayWindows.removeAll()
    }

    /// Fades out overlay windows over `duration` seconds, then removes them.
    func fadeOutAndHideOverlay(duration: TimeInterval = 0.4) {
        let windowsToFade = overlayWindows
        overlayWindows.removeAll()

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            for window in windowsToFade {
                window.animator().alphaValue = 0
            }
        }, completionHandler: {
            for window in windowsToFade {
                window.orderOut(nil)
                window.contentView = nil
            }
        })
    }

    func isShowingOverlay() -> Bool {
        return !overlayWindows.isEmpty
    }
}

// MARK: - Onboarding Video Player

/// NSViewRepresentable wrapping an AVPlayerLayer so HLS video plays
/// inside SwiftUI. Uses a custom NSView subclass to keep the player
/// layer sized to the view's bounds automatically.
private struct OnboardingVideoPlayerView: NSViewRepresentable {
    let player: AVPlayer?

    func makeNSView(context: Context) -> AVPlayerNSView {
        let view = AVPlayerNSView()
        view.player = player
        return view
    }

    func updateNSView(_ nsView: AVPlayerNSView, context: Context) {
        nsView.player = player
    }
}

private class AVPlayerNSView: NSView {
    var player: AVPlayer? {
        didSet { playerLayer.player = player }
    }

    private let playerLayer = AVPlayerLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        playerLayer.videoGravity = .resizeAspectFill
        layer?.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        playerLayer.frame = bounds
    }
}
