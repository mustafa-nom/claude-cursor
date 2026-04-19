//
//  CursorPillBubbleSnapshotTests.swift
//  claude-cursorTests
//
//  Perceptually-tolerant snapshot baselines for the shared
//  `CursorPillBubble` component and the consent bubble that wraps it.
//  Written in Phase 2 of the auto-click consent refactor to guarantee the
//  two cursor-side pills (navigation pointer + consent prompt) stay
//  perceptually identical after migrating to the shared renderer.
//
//  Tolerances — both set intentionally:
//    - `precision: 0.99` catches structural shifts (layout, geometry,
//      text position) even when color happens to match.
//    - `perceptualPrecision: 0.98` absorbs font-hinting / subpixel-AA /
//      color-profile jitter across macOS minor versions so the suite
//      doesn't turn into noise whenever the build host's OS updates.
//
//  Coverage — 24 cases = 6 states × 2 surfaces × 2 color modes:
//    Nav bubble (intrinsic, .center anchor):
//      1. scale 0.5, empty text          (initial pop-in)
//      2. scale 0.7, mid-bounce "r"      (bounce keyframe — catches arc regressions)
//      3. scale 0.9, tail-bounce "right" (tail keyframe — catches arc regressions)
//      4. scale 1.0, mid-stream "right"  (resting shadow during streaming)
//      5. scale 1.0, full "right here!"  (final resting state)
//      6. scale 1.0, opacity 0.3         (fade-out before fly-back)
//    Consent pill (constrained(maxWidth: 300), .topLeading anchor):
//      7. scale 0.5, empty text          (initial pop-in)
//      8. scale 0.7, mid-bounce empty    (bounce keyframe)
//      9. scale 0.9, tail-bounce partial (tail keyframe)
//      10. scale 1.0, mid-stream "want me"
//      11. scale 1.0, full consent text
//      12. scale 1.0, full + Yes/No button row (uses CursorBubbleConsentView)
//    × light + dark modes.
//
//  Baselines: first run records PNGs under __Snapshots__/. Subsequent runs
//  diff the rendered NSHostingView against the baseline at the declared
//  tolerances. To re-record after an intentional visual change, set
//  `isRecording = true` in `setUp()` and delete the old baselines.
//

import SnapshotTesting
import SwiftUI
import XCTest
@testable import claude_cursor

@MainActor
final class CursorPillBubbleSnapshotTests: XCTestCase {

    // Flip to `true` locally to overwrite baselines after an intentional
    // visual change. Leave `false` in version control so CI regressions are
    // actual failures rather than silently re-recorded baselines.
    private let shouldRecordNewBaselines: Bool = false

    override func setUp() {
        super.setUp()
        isRecording = shouldRecordNewBaselines
    }

    // MARK: - Canvas Sizes

    /// Nav-bubble canvas. Tight to the pill so shadow + scale bounce stay
    /// inside frame without a lot of wasted whitespace.
    private let navBubbleCanvasSize = CGSize(width: 260, height: 110)

    /// Consent-pill canvas (text only). Wider so wrapped long messages fit.
    private let consentPillCanvasSize = CGSize(width: 380, height: 150)

    /// Consent-view canvas (pill + Yes/No buttons). Taller than the pill-only
    /// canvas so the button row doesn't clip.
    private let consentFullViewCanvasSize = CGSize(width: 380, height: 220)

    // MARK: - Sample Text

    private let navBubbleFullText = "right here!"
    private let navBubbleMidStreamText = "right"
    private let navBubbleTailBounceText = "right"

    private let consentFullText = "want me to open a new tab and go to youtube?"
    private let consentMidStreamText = "want me"
    private let consentTailBounceText = "w"

    // MARK: - Nav Bubble Snapshots — Light Mode

    func test_navBubble_light_scale05_empty() {
        assertPillSnapshot(
            text: "",
            pillScale: 0.5,
            outerScale: 0.5,
            opacity: 1.0,
            sizing: .intrinsic,
            outerAnchor: .center,
            canvas: navBubbleCanvasSize,
            colorScheme: .light
        )
    }

    func test_navBubble_light_scale07_midBounce() {
        assertPillSnapshot(
            text: navBubbleTailBounceText,
            pillScale: 0.7,
            outerScale: 0.7,
            opacity: 1.0,
            sizing: .intrinsic,
            outerAnchor: .center,
            canvas: navBubbleCanvasSize,
            colorScheme: .light
        )
    }

    func test_navBubble_light_scale09_tailBounce() {
        assertPillSnapshot(
            text: navBubbleTailBounceText,
            pillScale: 0.9,
            outerScale: 0.9,
            opacity: 1.0,
            sizing: .intrinsic,
            outerAnchor: .center,
            canvas: navBubbleCanvasSize,
            colorScheme: .light
        )
    }

    func test_navBubble_light_scale10_midStream() {
        assertPillSnapshot(
            text: navBubbleMidStreamText,
            pillScale: 1.0,
            outerScale: 1.0,
            opacity: 1.0,
            sizing: .intrinsic,
            outerAnchor: .center,
            canvas: navBubbleCanvasSize,
            colorScheme: .light
        )
    }

    func test_navBubble_light_scale10_full() {
        assertPillSnapshot(
            text: navBubbleFullText,
            pillScale: 1.0,
            outerScale: 1.0,
            opacity: 1.0,
            sizing: .intrinsic,
            outerAnchor: .center,
            canvas: navBubbleCanvasSize,
            colorScheme: .light
        )
    }

    func test_navBubble_light_scale10_fading_opacity03() {
        assertPillSnapshot(
            text: navBubbleFullText,
            pillScale: 1.0,
            outerScale: 1.0,
            opacity: 0.3,
            sizing: .intrinsic,
            outerAnchor: .center,
            canvas: navBubbleCanvasSize,
            colorScheme: .light
        )
    }

    // MARK: - Nav Bubble Snapshots — Dark Mode

    func test_navBubble_dark_scale05_empty() {
        assertPillSnapshot(
            text: "",
            pillScale: 0.5,
            outerScale: 0.5,
            opacity: 1.0,
            sizing: .intrinsic,
            outerAnchor: .center,
            canvas: navBubbleCanvasSize,
            colorScheme: .dark
        )
    }

    func test_navBubble_dark_scale07_midBounce() {
        assertPillSnapshot(
            text: navBubbleTailBounceText,
            pillScale: 0.7,
            outerScale: 0.7,
            opacity: 1.0,
            sizing: .intrinsic,
            outerAnchor: .center,
            canvas: navBubbleCanvasSize,
            colorScheme: .dark
        )
    }

    func test_navBubble_dark_scale09_tailBounce() {
        assertPillSnapshot(
            text: navBubbleTailBounceText,
            pillScale: 0.9,
            outerScale: 0.9,
            opacity: 1.0,
            sizing: .intrinsic,
            outerAnchor: .center,
            canvas: navBubbleCanvasSize,
            colorScheme: .dark
        )
    }

    func test_navBubble_dark_scale10_midStream() {
        assertPillSnapshot(
            text: navBubbleMidStreamText,
            pillScale: 1.0,
            outerScale: 1.0,
            opacity: 1.0,
            sizing: .intrinsic,
            outerAnchor: .center,
            canvas: navBubbleCanvasSize,
            colorScheme: .dark
        )
    }

    func test_navBubble_dark_scale10_full() {
        assertPillSnapshot(
            text: navBubbleFullText,
            pillScale: 1.0,
            outerScale: 1.0,
            opacity: 1.0,
            sizing: .intrinsic,
            outerAnchor: .center,
            canvas: navBubbleCanvasSize,
            colorScheme: .dark
        )
    }

    func test_navBubble_dark_scale10_fading_opacity03() {
        assertPillSnapshot(
            text: navBubbleFullText,
            pillScale: 1.0,
            outerScale: 1.0,
            opacity: 0.3,
            sizing: .intrinsic,
            outerAnchor: .center,
            canvas: navBubbleCanvasSize,
            colorScheme: .dark
        )
    }

    // MARK: - Consent Pill Snapshots — Light Mode

    func test_consentPill_light_scale05_empty() {
        assertPillSnapshot(
            text: "",
            pillScale: 1.0,
            outerScale: 0.5,
            opacity: 1.0,
            sizing: .constrained(maxWidth: 300),
            outerAnchor: .topLeading,
            canvas: consentPillCanvasSize,
            colorScheme: .light
        )
    }

    func test_consentPill_light_scale07_midBounce() {
        assertPillSnapshot(
            text: consentTailBounceText,
            pillScale: 1.0,
            outerScale: 0.7,
            opacity: 1.0,
            sizing: .constrained(maxWidth: 300),
            outerAnchor: .topLeading,
            canvas: consentPillCanvasSize,
            colorScheme: .light
        )
    }

    func test_consentPill_light_scale09_tailBounce() {
        assertPillSnapshot(
            text: consentMidStreamText,
            pillScale: 1.0,
            outerScale: 0.9,
            opacity: 1.0,
            sizing: .constrained(maxWidth: 300),
            outerAnchor: .topLeading,
            canvas: consentPillCanvasSize,
            colorScheme: .light
        )
    }

    func test_consentPill_light_scale10_midStream() {
        assertPillSnapshot(
            text: consentMidStreamText,
            pillScale: 1.0,
            outerScale: 1.0,
            opacity: 1.0,
            sizing: .constrained(maxWidth: 300),
            outerAnchor: .topLeading,
            canvas: consentPillCanvasSize,
            colorScheme: .light
        )
    }

    func test_consentPill_light_scale10_full() {
        assertPillSnapshot(
            text: consentFullText,
            pillScale: 1.0,
            outerScale: 1.0,
            opacity: 1.0,
            sizing: .constrained(maxWidth: 300),
            outerAnchor: .topLeading,
            canvas: consentPillCanvasSize,
            colorScheme: .light
        )
    }

    func test_consentPill_light_scale10_fullWithButtons() {
        assertConsentFullViewSnapshot(
            messageText: consentFullText,
            isShowingButtons: true,
            bubbleScale: 1.0,
            canvas: consentFullViewCanvasSize,
            colorScheme: .light
        )
    }

    // MARK: - Consent Pill Snapshots — Dark Mode

    func test_consentPill_dark_scale05_empty() {
        assertPillSnapshot(
            text: "",
            pillScale: 1.0,
            outerScale: 0.5,
            opacity: 1.0,
            sizing: .constrained(maxWidth: 300),
            outerAnchor: .topLeading,
            canvas: consentPillCanvasSize,
            colorScheme: .dark
        )
    }

    func test_consentPill_dark_scale07_midBounce() {
        assertPillSnapshot(
            text: consentTailBounceText,
            pillScale: 1.0,
            outerScale: 0.7,
            opacity: 1.0,
            sizing: .constrained(maxWidth: 300),
            outerAnchor: .topLeading,
            canvas: consentPillCanvasSize,
            colorScheme: .dark
        )
    }

    func test_consentPill_dark_scale09_tailBounce() {
        assertPillSnapshot(
            text: consentMidStreamText,
            pillScale: 1.0,
            outerScale: 0.9,
            opacity: 1.0,
            sizing: .constrained(maxWidth: 300),
            outerAnchor: .topLeading,
            canvas: consentPillCanvasSize,
            colorScheme: .dark
        )
    }

    func test_consentPill_dark_scale10_midStream() {
        assertPillSnapshot(
            text: consentMidStreamText,
            pillScale: 1.0,
            outerScale: 1.0,
            opacity: 1.0,
            sizing: .constrained(maxWidth: 300),
            outerAnchor: .topLeading,
            canvas: consentPillCanvasSize,
            colorScheme: .dark
        )
    }

    func test_consentPill_dark_scale10_full() {
        assertPillSnapshot(
            text: consentFullText,
            pillScale: 1.0,
            outerScale: 1.0,
            opacity: 1.0,
            sizing: .constrained(maxWidth: 300),
            outerAnchor: .topLeading,
            canvas: consentPillCanvasSize,
            colorScheme: .dark
        )
    }

    func test_consentPill_dark_scale10_fullWithButtons() {
        assertConsentFullViewSnapshot(
            messageText: consentFullText,
            isShowingButtons: true,
            bubbleScale: 1.0,
            canvas: consentFullViewCanvasSize,
            colorScheme: .dark
        )
    }

    // MARK: - Helpers

    /// Renders a `CursorPillBubble` inside a fixed-size canvas with the
    /// caller-specified outer scale + anchor (nav uses `.center`, consent
    /// uses `.topLeading`). Baselines use both `precision` and
    /// `perceptualPrecision`: the first catches structural shifts, the
    /// second absorbs font-hinting noise across OS minor versions.
    private func assertPillSnapshot(
        text: String,
        pillScale: CGFloat,
        outerScale: CGFloat,
        opacity: Double,
        sizing: CursorPillBubbleSizing,
        outerAnchor: UnitPoint,
        canvas: CGSize,
        colorScheme: ColorScheme,
        file: StaticString = #filePath,
        testName: String = #function,
        line: UInt = #line
    ) {
        let pill = CursorPillBubble(
            text: text,
            scale: pillScale,
            opacity: opacity,
            sizing: sizing
        )

        let subject = pill
            .scaleEffect(outerScale, anchor: outerAnchor)
            .padding(24)
            .frame(
                width: canvas.width,
                height: canvas.height,
                alignment: .topLeading
            )
            .background(colorScheme == .dark ? Color.black : Color.white)
            .environment(\.colorScheme, colorScheme)

        let hostingView = NSHostingView(rootView: subject)
        hostingView.frame = NSRect(origin: .zero, size: canvas)
        hostingView.layoutSubtreeIfNeeded()

        assertSnapshot(
            of: hostingView,
            as: .image(
                precision: 0.99,
                perceptualPrecision: 0.98,
                size: canvas,
                appearance: appearance(for: colorScheme)
            ),
            file: file,
            testName: testName,
            line: line
        )
    }

    /// Renders the full `CursorBubbleConsentView` (pill + Yes/No button
    /// row) so the one snapshot that cares about the buttons captures them
    /// against the shared renderer. The VStack's own `.scaleEffect` replays
    /// the pop-in — set `bubbleScale` = 1.0 for the resting state.
    private func assertConsentFullViewSnapshot(
        messageText: String,
        isShowingButtons: Bool,
        bubbleScale: CGFloat,
        canvas: CGSize,
        colorScheme: ColorScheme,
        file: StaticString = #filePath,
        testName: String = #function,
        line: UInt = #line
    ) {
        let viewModel = CursorBubbleConsentViewModel()
        viewModel.messageText = messageText
        viewModel.isShowingButtons = isShowingButtons
        viewModel.bubbleScale = bubbleScale

        let consentView = CursorBubbleConsentView(
            viewModel: viewModel,
            onAcceptButtonTapped: {},
            onRejectButtonTapped: {}
        )

        let subject = consentView
            .padding(24)
            .frame(
                width: canvas.width,
                height: canvas.height,
                alignment: .topLeading
            )
            .background(colorScheme == .dark ? Color.black : Color.white)
            .environment(\.colorScheme, colorScheme)

        let hostingView = NSHostingView(rootView: subject)
        hostingView.frame = NSRect(origin: .zero, size: canvas)
        hostingView.layoutSubtreeIfNeeded()

        assertSnapshot(
            of: hostingView,
            as: .image(
                precision: 0.99,
                perceptualPrecision: 0.98,
                size: canvas,
                appearance: appearance(for: colorScheme)
            ),
            file: file,
            testName: testName,
            line: line
        )
    }

    /// Maps SwiftUI `ColorScheme` to `NSAppearance`. Passed to the snapshot
    /// renderer so the NSHostingView materializes with the right system
    /// colors (dark aqua background, etc.) even though our pill doesn't
    /// use system colors directly — future changes might.
    private func appearance(for colorScheme: ColorScheme) -> NSAppearance? {
        switch colorScheme {
        case .light:
            return NSAppearance(named: .aqua)
        case .dark:
            return NSAppearance(named: .darkAqua)
        @unknown default:
            return NSAppearance(named: .aqua)
        }
    }
}
