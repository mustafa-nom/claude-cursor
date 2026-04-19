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

// MARK: - Overlay Hosting View (selective click-through for draggable explainer pills)

/// NSHostingView subclass used as the content view of every `OverlayWindow`.
///
/// The overlay window is normally click-through (`ignoresMouseEvents = true`) so it
/// never steals mouse events from the app underneath. When the multi-cursor explainer
/// tool is active the pills need to be draggable, so we flip `ignoresMouseEvents`
/// off — but we must still pass every click *outside* the pill rects through to the
/// app below. This subclass achieves that by overriding `hitTest` to return `nil`
/// (no hit) unless the mouse point is inside one of the registered pill rects.
///
/// `interactivePillRects` is refreshed from SwiftUI via a PreferenceKey (see
/// `InteractivePillRectsKey`) each time pill layout changes.
final class OverlayHostingView<Content: View>: NSHostingView<Content> {
    /// Rectangles (in this view's coordinate space) where mouse events should be
    /// captured instead of falling through to the app below. Everything outside
    /// these rects stays click-through.
    var interactivePillRects: [CGRect] = []

    override func hitTest(_ point: NSPoint) -> NSView? {
        for pillRect in interactivePillRects where pillRect.contains(point) {
            return super.hitTest(point)
        }
        return nil
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

/// Per-pill measured sizes keyed by explainer element id. Each
/// `ExplainerCursorMarker` publishes its rendered pill size so the group-level
/// layout resolver can lay out real (not estimated) rectangles.
struct PillSizePreferenceKey: PreferenceKey {
    static var defaultValue: [UUID: CGSize] = [:]
    static func reduce(value: inout [UUID: CGSize], nextValue: () -> [UUID: CGSize]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

/// Per-pill on-screen rects (in the overlay's coordinate space). `BlueCursorView`
/// collects these and forwards them to `OverlayHostingView.interactivePillRects`
/// so only the pills — not the surrounding transparent overlay — capture mouse
/// events while a group is active.
struct InteractivePillRectsPreferenceKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

/// User-committed drag translation per pill. When the user drags a pill, the
/// marker records the final translation (relative to the resolver's computed
/// center) in its own `@State` and publishes it up so the resolver can treat
/// that pill as a fixed rectangle and flow other pills around it.
struct PinnedPillOffsetsPreferenceKey: PreferenceKey {
    static var defaultValue: [UUID: CGSize] = [:]
    static func reduce(value: inout [UUID: CGSize], nextValue: () -> [UUID: CGSize]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
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
    /// Called whenever the on-screen rects for draggable explainer pills change.
    /// `OverlayWindow` wires this into `OverlayHostingView.interactivePillRects`
    /// so mouse events are captured only inside the pills (click-through stays
    /// intact everywhere else).
    let onInteractivePillRectsChanged: ([CGRect]) -> Void
    /// Called when the explainer group presence flips (nil <-> non-nil).
    /// `OverlayWindow` uses this to toggle `window.ignoresMouseEvents` so the
    /// overlay only captures mouse events while pills are actually visible.
    let onExplainerGroupPresenceChanged: (Bool) -> Void

    @State private var cursorPosition: CGPoint
    @State private var isCursorOnThisScreen: Bool

    /// Real pill sizes reported by each `ExplainerCursorMarker` via
    /// `PillSizePreferenceKey`. The layout resolver uses these for accurate
    /// overlap detection; before a measurement arrives it falls back to a
    /// character-count estimate.
    @State private var measuredExplainerPillSizesById: [UUID: CGSize] = [:]
    /// Per-pill drag translations committed by the user (relative to the
    /// resolver's computed center). Flowing these back into the resolver lets
    /// other pills flow around a pinned pill while the pinned pill stays put.
    @State private var userPinnedPillOffsetsById: [UUID: CGSize] = [:]

    init(
        screenFrame: CGRect,
        isFirstAppearance: Bool,
        companionManager: CompanionManager,
        onInteractivePillRectsChanged: @escaping ([CGRect]) -> Void = { _ in },
        onExplainerGroupPresenceChanged: @escaping (Bool) -> Void = { _ in }
    ) {
        self.screenFrame = screenFrame
        self.isFirstAppearance = isFirstAppearance
        self.companionManager = companionManager
        self.onInteractivePillRectsChanged = onInteractivePillRectsChanged
        self.onExplainerGroupPresenceChanged = onExplainerGroupPresenceChanged

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
            // main cursor and fly to their targets simultaneously. Pill
            // positions are computed once per render by a group-level
            // resolver that de-overlaps and clamps them inside the screen.
            if let explainerGroup = companionManager.activeExplainerCursorGroup {
                let elementsOnThisScreen = explainerGroup.elements.filter { element in
                    screenFrame.contains(CGPoint(
                        x: element.screenLocation.x,
                        y: element.screenLocation.y
                    ))
                }
                let overlayBoundsInSwiftUI = CGRect(
                    origin: .zero,
                    size: CGSize(width: screenFrame.width, height: screenFrame.height)
                )
                let resolvedPillLayoutsById = resolveExplainerPillLayouts(
                    elementsOnThisScreen: elementsOnThisScreen,
                    overlayBoundsInSwiftUI: overlayBoundsInSwiftUI
                )
                ForEach(Array(elementsOnThisScreen.enumerated()), id: \.element.id) { index, element in
                    let targetPositionInSwiftUI = convertScreenPointToSwiftUICoordinates(
                        element.screenLocation
                    )
                    // Fall back to the cursor's target position if the resolver
                    // hasn't produced a layout yet on the first render frame.
                    let resolvedPillCenter = resolvedPillLayoutsById[element.id]?.pillCenterInSwiftUI
                        ?? targetPositionInSwiftUI
                    ExplainerCursorMarker(
                        element: element,
                        mainCursorPositionInSwiftUI: cursorPosition,
                        targetPositionInSwiftUI: targetPositionInSwiftUI,
                        resolvedPillCenterInSwiftUI: resolvedPillCenter,
                        staggerIndex: index,
                        isReturningToMain: companionManager.isExplainerGroupReturning
                    )
                }
            }
        }
        .onPreferenceChange(PillSizePreferenceKey.self) { sizesById in
            measuredExplainerPillSizesById = sizesById
        }
        .onPreferenceChange(PinnedPillOffsetsPreferenceKey.self) { offsetsById in
            userPinnedPillOffsetsById = offsetsById
        }
        .onPreferenceChange(InteractivePillRectsPreferenceKey.self) { rectsById in
            // Forward rects up to the NSHostingView subclass so its hitTest
            // override can pass clicks through everywhere except on a pill.
            onInteractivePillRectsChanged(Array(rectsById.values))
        }
        .onChange(of: companionManager.activeExplainerCursorGroup?.createdAt) { newCreatedAt in
            // Presence flip — hosting window toggles ignoresMouseEvents so the
            // overlay only captures events while pills are visible. We key on
            // `createdAt` (a Date) since `ExplainerCursorGroup` isn't Equatable.
            onExplainerGroupPresenceChanged(newCreatedAt != nil)
            if newCreatedAt == nil {
                // Group dismissed — clear stale layout inputs so the next group
                // starts clean (pinned offsets are also cleared when the marker
                // views are destroyed).
                measuredExplainerPillSizesById = [:]
                userPinnedPillOffsetsById = [:]
                onInteractivePillRectsChanged([])
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

    // MARK: - Explainer Pill Layout

    /// Build `ExplainerPillLayoutResolver` inputs from the filtered elements
    /// and invoke the resolver. Runs on every render pass — SwiftUI re-runs
    /// this automatically when measured sizes, pinned offsets, the element
    /// list, or the cursor position change, so pill positions stay live.
    private func resolveExplainerPillLayouts(
        elementsOnThisScreen: [CompanionManager.ExplainerElement],
        overlayBoundsInSwiftUI: CGRect
    ) -> [UUID: ExplainerPillLayoutResolver.ResolvedPillLayout] {
        let resolverInputs: [ExplainerPillLayoutResolver.ElementInput] = elementsOnThisScreen
            .enumerated()
            .map { index, element in
                ExplainerPillLayoutResolver.ElementInput(
                    id: element.id,
                    staggerIndex: index,
                    cursorPositionInSwiftUI: convertScreenPointToSwiftUICoordinates(element.screenLocation),
                    labelCharacterCount: element.labelText.count,
                    descriptionCharacterCount: element.descriptionText.count
                )
            }
        let resolver = ExplainerPillLayoutResolver(
            elementsInput: resolverInputs,
            overlayBoundsInSwiftUI: overlayBoundsInSwiftUI,
            measuredPillSizesById: measuredExplainerPillSizesById,
            userPinnedOffsetsById: userPinnedPillOffsetsById
        )
        return resolver.resolve()
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
/// Group-level layout for the multi-cursor explainer pills.
///
/// Each `ExplainerCursorMarker` used to compute its own pill offset locally, which
/// meant pills had no awareness of each other and frequently overlapped. This
/// resolver runs once per layout pass with the full group's state and returns a
/// final pill center per element, after:
///   1. Seeding each pill at the original circular fan-out offset.
///   2. Clamping every seeded rect inside the screen bounds (all four edges).
///   3. Running up to 6 greedy overlap-resolution passes that nudge intersecting
///      pairs apart; pinned pills (user-dragged) are immovable on the receiving
///      side but still push the others.
///   4. Re-clamping after every pass.
///
/// The resolver is pure — all input is passed in and no internal state is kept.
/// SwiftUI re-runs it whenever any input changes.
struct ExplainerPillLayoutResolver {
    /// Minimum distance in points between a pill's edge and the screen edge.
    static let screenEdgeMargin: CGFloat = 8
    /// Estimated pill sizes are used only until the real measurement arrives via
    /// `PillSizePreferenceKey`. Clamps keep the estimate from going wild when
    /// labels are extremely short or extremely long.
    static let minimumEstimatedPillWidth: CGFloat = 60
    static let maximumEstimatedPillWidth: CGFloat = 220

    /// Input element to lay out.
    struct ElementInput {
        let id: UUID
        let staggerIndex: Int
        let cursorPositionInSwiftUI: CGPoint
        /// Character count-based estimate used when the marker hasn't yet
        /// published its measured size. The estimate is kept conservative so
        /// overlap resolution doesn't thrash when real sizes arrive.
        let labelCharacterCount: Int
        let descriptionCharacterCount: Int
    }

    /// Output — final pill center in the overlay's SwiftUI coordinate space.
    struct ResolvedPillLayout {
        let id: UUID
        let pillCenterInSwiftUI: CGPoint
        let pillSizeUsedForLayout: CGSize
    }

    let elementsInput: [ElementInput]
    let overlayBoundsInSwiftUI: CGRect
    let measuredPillSizesById: [UUID: CGSize]
    let userPinnedOffsetsById: [UUID: CGSize]

    /// Compute final pill centers.
    func resolve() -> [UUID: ResolvedPillLayout] {
        guard !elementsInput.isEmpty else { return [:] }

        var workingRectsById: [UUID: CGRect] = [:]
        var sizeUsedByElementId: [UUID: CGSize] = [:]

        for elementInput in elementsInput {
            let pillSize = pillSizeForElement(elementInput)
            sizeUsedByElementId[elementInput.id] = pillSize

            let seededCenter = seedCenterForElement(elementInput, pillSize: pillSize)
            let clampedCenter = clampCenterInsideScreenBounds(seededCenter, pillSize: pillSize)
            workingRectsById[elementInput.id] = rectCentered(on: clampedCenter, size: pillSize)
        }

        let maximumResolutionPasses = 6
        for _ in 0..<maximumResolutionPasses {
            let movedAnyPillDuringThisPass = runOneOverlapResolutionPass(
                workingRectsById: &workingRectsById
            )
            guard movedAnyPillDuringThisPass else { break }
        }

        var resolvedLayouts: [UUID: ResolvedPillLayout] = [:]
        for elementInput in elementsInput {
            guard let finalRect = workingRectsById[elementInput.id],
                  let pillSize = sizeUsedByElementId[elementInput.id] else {
                continue
            }
            resolvedLayouts[elementInput.id] = ResolvedPillLayout(
                id: elementInput.id,
                pillCenterInSwiftUI: CGPoint(x: finalRect.midX, y: finalRect.midY),
                pillSizeUsedForLayout: pillSize
            )
        }
        return resolvedLayouts
    }

    // MARK: - Seeding

    /// The original circular fan-out offset used before group layout existed.
    /// We keep this as the seed so visual behavior matches the previous design
    /// when there are no overlaps to resolve. If the user has dragged the pill,
    /// the pinned offset replaces the fan-out entirely.
    private func seedCenterForElement(
        _ elementInput: ElementInput,
        pillSize: CGSize
    ) -> CGPoint {
        if let userPinnedOffset = userPinnedOffsetsById[elementInput.id] {
            return CGPoint(
                x: elementInput.cursorPositionInSwiftUI.x + userPinnedOffset.width,
                y: elementInput.cursorPositionInSwiftUI.y + userPinnedOffset.height
            )
        }

        let staggerIndex = elementInput.staggerIndex
        let angle = (Double(staggerIndex) * 2.3) - 2.85
        let radius: CGFloat = 26 + CGFloat(min(staggerIndex, 5)) * 5
        let offsetX = CGFloat(cos(angle)) * radius + CGFloat(staggerIndex - 3) * 10
        let offsetY = -36 - CGFloat(min(staggerIndex, 6)) * 5
        return CGPoint(
            x: elementInput.cursorPositionInSwiftUI.x + offsetX,
            y: elementInput.cursorPositionInSwiftUI.y + offsetY
        )
    }

    /// Two-phase sizing — real measured size if we have one, otherwise a
    /// character-count estimate. Estimates are only used during the very first
    /// render frame; SwiftUI re-runs the resolver as soon as the measurement
    /// preference fires.
    private func pillSizeForElement(_ elementInput: ElementInput) -> CGSize {
        if let measuredPillSize = measuredPillSizesById[elementInput.id],
           measuredPillSize.width > 0, measuredPillSize.height > 0 {
            return measuredPillSize
        }

        let estimatedWidth = min(
            Self.maximumEstimatedPillWidth,
            max(
                Self.minimumEstimatedPillWidth,
                CGFloat(elementInput.labelCharacterCount) * 6.5
                    + CGFloat(elementInput.descriptionCharacterCount) * 5.5
                    + 16
            )
        )
        let estimatedHeight: CGFloat = elementInput.descriptionCharacterCount == 0 ? 22 : 40
        return CGSize(width: estimatedWidth, height: estimatedHeight)
    }

    // MARK: - Clamping

    /// Shift `center` so a pill of `pillSize` centered there fits entirely
    /// inside `overlayBoundsInSwiftUI` with `screenEdgeMargin` padding. Handles
    /// all four edges — the pre-refactor code only clamped left/right/top.
    private func clampCenterInsideScreenBounds(
        _ center: CGPoint,
        pillSize: CGSize
    ) -> CGPoint {
        var clampedCenter = center
        let halfWidth = pillSize.width / 2
        let halfHeight = pillSize.height / 2
        let minimumAllowedCenterX = overlayBoundsInSwiftUI.minX + Self.screenEdgeMargin + halfWidth
        let maximumAllowedCenterX = overlayBoundsInSwiftUI.maxX - Self.screenEdgeMargin - halfWidth
        let minimumAllowedCenterY = overlayBoundsInSwiftUI.minY + Self.screenEdgeMargin + halfHeight
        let maximumAllowedCenterY = overlayBoundsInSwiftUI.maxY - Self.screenEdgeMargin - halfHeight

        if minimumAllowedCenterX <= maximumAllowedCenterX {
            clampedCenter.x = min(max(clampedCenter.x, minimumAllowedCenterX), maximumAllowedCenterX)
        }
        if minimumAllowedCenterY <= maximumAllowedCenterY {
            clampedCenter.y = min(max(clampedCenter.y, minimumAllowedCenterY), maximumAllowedCenterY)
        }
        return clampedCenter
    }

    private func rectCentered(on center: CGPoint, size: CGSize) -> CGRect {
        return CGRect(
            x: center.x - size.width / 2,
            y: center.y - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    // MARK: - Overlap resolution

    /// One pass of greedy pair-wise overlap resolution. For each intersecting
    /// pair, compute the minimum translation vector and split the push 50/50
    /// along the shorter axis. Pinned pills never move themselves. Returns true
    /// if any pill moved so the caller can early-exit the loop.
    private func runOneOverlapResolutionPass(
        workingRectsById: inout [UUID: CGRect]
    ) -> Bool {
        var movedAnyPill = false
        let elementIdsInStaggerOrder = elementsInput
            .sorted(by: { $0.staggerIndex < $1.staggerIndex })
            .map { $0.id }

        for leftIndex in 0..<elementIdsInStaggerOrder.count {
            for rightIndex in (leftIndex + 1)..<elementIdsInStaggerOrder.count {
                let leftId = elementIdsInStaggerOrder[leftIndex]
                let rightId = elementIdsInStaggerOrder[rightIndex]
                guard var leftRect = workingRectsById[leftId],
                      var rightRect = workingRectsById[rightId] else { continue }
                guard leftRect.intersects(rightRect) else { continue }

                let leftIsPinned = userPinnedOffsetsById[leftId] != nil
                let rightIsPinned = userPinnedOffsetsById[rightId] != nil
                // Both pinned — nothing we can move. The user wanted it this way.
                if leftIsPinned && rightIsPinned { continue }

                let overlapWidth = min(leftRect.maxX, rightRect.maxX) - max(leftRect.minX, rightRect.minX)
                let overlapHeight = min(leftRect.maxY, rightRect.maxY) - max(leftRect.minY, rightRect.minY)
                // Minimum translation vector — push along the axis with the smaller overlap.
                let pushAlongX = overlapWidth < overlapHeight
                let leftCenterIsToTheLeftOfRight = leftRect.midX < rightRect.midX
                let leftCenterIsAboveRight = leftRect.midY < rightRect.midY
                var leftDeltaX: CGFloat = 0
                var leftDeltaY: CGFloat = 0
                var rightDeltaX: CGFloat = 0
                var rightDeltaY: CGFloat = 0

                if pushAlongX {
                    let signedPush: CGFloat = leftCenterIsToTheLeftOfRight ? -overlapWidth : overlapWidth
                    leftDeltaX = signedPush / 2
                    rightDeltaX = -signedPush / 2
                } else {
                    let signedPush: CGFloat = leftCenterIsAboveRight ? -overlapHeight : overlapHeight
                    leftDeltaY = signedPush / 2
                    rightDeltaY = -signedPush / 2
                }

                // Route the entire push to the non-pinned side so pinned pills stay put.
                if leftIsPinned {
                    rightDeltaX += leftDeltaX
                    rightDeltaY += leftDeltaY
                    leftDeltaX = 0
                    leftDeltaY = 0
                } else if rightIsPinned {
                    leftDeltaX += rightDeltaX
                    leftDeltaY += rightDeltaY
                    rightDeltaX = 0
                    rightDeltaY = 0
                }

                if leftDeltaX != 0 || leftDeltaY != 0 {
                    leftRect = leftRect.offsetBy(dx: leftDeltaX, dy: leftDeltaY)
                    let reClampedLeftCenter = clampCenterInsideScreenBounds(
                        CGPoint(x: leftRect.midX, y: leftRect.midY),
                        pillSize: leftRect.size
                    )
                    leftRect = rectCentered(on: reClampedLeftCenter, size: leftRect.size)
                    workingRectsById[leftId] = leftRect
                    movedAnyPill = true
                }
                if rightDeltaX != 0 || rightDeltaY != 0 {
                    rightRect = rightRect.offsetBy(dx: rightDeltaX, dy: rightDeltaY)
                    let reClampedRightCenter = clampCenterInsideScreenBounds(
                        CGPoint(x: rightRect.midX, y: rightRect.midY),
                        pillSize: rightRect.size
                    )
                    rightRect = rectCentered(on: reClampedRightCenter, size: rightRect.size)
                    workingRectsById[rightId] = rightRect
                    movedAnyPill = true
                }
            }
        }
        return movedAnyPill
    }
}

private struct ExplainerCursorMarker: View {
    let element: CompanionManager.ExplainerElement
    let mainCursorPositionInSwiftUI: CGPoint
    let targetPositionInSwiftUI: CGPoint
    /// Pill center resolved by the group-level `ExplainerPillLayoutResolver`.
    /// Already de-overlapped and clamped inside the screen bounds.
    let resolvedPillCenterInSwiftUI: CGPoint
    let staggerIndex: Int
    let isReturningToMain: Bool

    @State private var hasArrivedAtTarget: Bool = false
    @State private var markerScale: CGFloat = 0.3
    @State private var markerOpacity: Double = 0.0

    /// Drag translation committed when the user releases a drag. Once set, the
    /// pill stays at `resolvedPillCenter + userPinnedTranslation` until the
    /// group dismisses (which destroys this view and its @State with it).
    @State private var userPinnedTranslation: CGSize? = nil
    /// Live drag translation during an in-progress drag. Reset to .zero when
    /// the gesture ends (the final value is folded into `userPinnedTranslation`).
    @GestureState private var activeDragTranslation: CGSize = .zero

    private let cursorImageSize: CGFloat = 20
    private let spawnStaggerSeconds: Double = 0.12
    private let returnStaggerSeconds: Double = 0.08

    private var currentCursorPosition: CGPoint {
        if isReturningToMain {
            return mainCursorPositionInSwiftUI
        }
        return hasArrivedAtTarget ? targetPositionInSwiftUI : mainCursorPositionInSwiftUI
    }

    /// Final on-screen pill center — resolver output plus any committed drag
    /// translation plus the live translation from an in-progress drag. Used by
    /// both the pill `.position()` and the connecting line's endpoint, so the
    /// line follows every drag automatically.
    private var effectivePillCenterInSwiftUI: CGPoint {
        let pinnedTranslation = userPinnedTranslation ?? .zero
        return CGPoint(
            x: resolvedPillCenterInSwiftUI.x + pinnedTranslation.width + activeDragTranslation.width,
            y: resolvedPillCenterInSwiftUI.y + pinnedTranslation.height + activeDragTranslation.height
        )
    }

    /// Cursor asset points roughly up-left by default; rotate so the tip aims at the explainer target.
    private var cursorRotationTowardTargetDegrees: Double {
        let dx = targetPositionInSwiftUI.x - currentCursorPosition.x
        let dy = targetPositionInSwiftUI.y - currentCursorPosition.y
        guard abs(dx) + abs(dy) > 2 else { return -35 }
        let radians = atan2(Double(dy), Double(dx))
        return radians * 180 / .pi - 55
    }

    var body: some View {
        ZStack {
            if !element.labelText.isEmpty {
                let pillCenter = effectivePillCenterInSwiftUI

                // The connecting line is drawn first so the pill sits on top.
                // The line runs from the pill's bottom edge to the sub-cursor;
                // because both endpoints live in the same coordinate space and
                // `pillCenter` already includes the live drag translation, the
                // line follows the pill through every drag.
                let estimatedPillHalfHeight: CGFloat = 28
                Path { path in
                    path.move(to: CGPoint(x: pillCenter.x, y: pillCenter.y + estimatedPillHalfHeight))
                    path.addLine(to: currentCursorPosition)
                }
                .stroke(element.assignedColor.opacity(0.55), lineWidth: 1.5)
                .opacity(markerOpacity * 0.95)
                .allowsHitTesting(false)

                // The pill itself — the only interactive part of the marker.
                // A GeometryReader in .background measures its rendered size so
                // the resolver can lay out real (not estimated) rectangles;
                // another GeometryReader publishes the pill's on-screen rect so
                // the hosting view's hitTest only captures clicks on the pill.
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
                .background(pillSizeMeasurementReporter)
                .background(pillInteractiveRectReporter(pillCenter: pillCenter))
                .preference(
                    key: PinnedPillOffsetsPreferenceKey.self,
                    value: userPinnedTranslation.map { [element.id: $0] } ?? [:]
                )
                .scaleEffect(markerScale)
                .opacity(markerOpacity)
                .position(x: pillCenter.x, y: pillCenter.y)
                .gesture(pillDragGesture)
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
                .position(currentCursorPosition)
                .allowsHitTesting(false)
        }
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
        .animation(.spring(response: 0.5, dampingFraction: 0.7), value: currentCursorPosition)
        .animation(.spring(response: 0.5, dampingFraction: 0.7), value: resolvedPillCenterInSwiftUI)
    }

    /// Drag gesture for repositioning the pill. `minimumDistance: 2` lets a
    /// sloppy click still feel intentional. During the drag the translation
    /// flows through `activeDragTranslation` (auto-resets when the gesture
    /// ends); on release we commit the final translation into the persistent
    /// `userPinnedTranslation`, additively so repeated drags accumulate.
    private var pillDragGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .updating($activeDragTranslation) { dragValue, liveTranslation, _ in
                liveTranslation = dragValue.translation
            }
            .onEnded { dragValue in
                let previousPinnedTranslation = userPinnedTranslation ?? .zero
                userPinnedTranslation = CGSize(
                    width: previousPinnedTranslation.width + dragValue.translation.width,
                    height: previousPinnedTranslation.height + dragValue.translation.height
                )
            }
    }

    /// Publishes the pill's real rendered size up to `BlueCursorView` so the
    /// group-level resolver can lay out actual rectangles instead of estimates.
    private var pillSizeMeasurementReporter: some View {
        GeometryReader { geometryProxy in
            Color.clear.preference(
                key: PillSizePreferenceKey.self,
                value: [element.id: geometryProxy.size]
            )
        }
    }

    /// Publishes the pill's on-screen rect (centered on `pillCenter` with the
    /// measured size) so `OverlayHostingView.hitTest` can capture mouse events
    /// inside the pill and pass everything else through to the app below.
    private func pillInteractiveRectReporter(pillCenter: CGPoint) -> some View {
        GeometryReader { geometryProxy in
            let rectCenteredOnPill = CGRect(
                x: pillCenter.x - geometryProxy.size.width / 2,
                y: pillCenter.y - geometryProxy.size.height / 2,
                width: geometryProxy.size.width,
                height: geometryProxy.size.height
            )
            Color.clear.preference(
                key: InteractivePillRectsPreferenceKey.self,
                value: [element.id: rectCenteredOnPill]
            )
        }
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

            // Weak references break the retention cycle between the hosting
            // view and the callbacks buried in its SwiftUI root view. The
            // window retains the hosting view (as its contentView) and the
            // `overlayWindows` array retains the window, so weak captures here
            // are safe — the window owns the real lifetime.
            weak var weakHostingView: OverlayHostingView<BlueCursorView>?
            weak var weakWindow: OverlayWindow? = window

            let contentView = BlueCursorView(
                screenFrame: screen.frame,
                isFirstAppearance: isFirstAppearance,
                companionManager: companionManager,
                onInteractivePillRectsChanged: { interactivePillRects in
                    // Passing rects into the hosting view lets its hitTest
                    // capture mouse events only inside pills; outside the
                    // pills the overlay remains click-through.
                    weakHostingView?.interactivePillRects = interactivePillRects
                },
                onExplainerGroupPresenceChanged: { explainerGroupIsActive in
                    // When an explainer group is active we need pills to
                    // accept drag gestures; when idle the overlay goes back to
                    // fully click-through so no clicks are ever stolen from
                    // the app underneath.
                    weakWindow?.ignoresMouseEvents = !explainerGroupIsActive
                }
            )

            let hostingView = OverlayHostingView(rootView: contentView)
            hostingView.frame = screen.frame
            weakHostingView = hostingView
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
