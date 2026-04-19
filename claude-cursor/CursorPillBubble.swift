//
//  CursorPillBubble.swift
//  claude-cursor
//
//  Shared SwiftUI renderer for the terracotta pill used on both cursor-side
//  surfaces: the navigation pointer bubble (`OverlayWindow.BlueCursorView`)
//  and the consent prompt (`CursorBubbleConsentPromptController`). Extracted
//  in Phase 2 so future styling changes touch one view instead of two.
//
//  Scale semantics:
//    - `scale` drives the dynamic shadow formula only. It does NOT apply a
//      `scaleEffect` internally — callers wrap the bubble with their own
//      `.scaleEffect(_:anchor:)` because the two surfaces use different
//      anchors (nav bubble uses implicit `.center`, consent pill uses
//      `.topLeading` on an outer container that also scales the button row).
//    - When `scale == 1.0` the shadow converges to `(opacity 0.5, radius 6)`,
//      which matches the consent pill's prior static-shadow styling exactly.
//      Nav bubble animates from 0.5 → 1.0 on appearance so its shadow fades
//      from a wide glow into the resting pill.
//
//  Sizing semantics:
//    - `.intrinsic` — `.fixedSize()` on the composed pill. Matches nav
//      bubble, which sizes to its (short) text so it can be center-positioned
//      via `.position(...)`.
//    - `.constrained(maxWidth:)` — bounds the text frame before padding so
//      the pill wraps to multiple lines when the consent message is long.
//

import SwiftUI

enum CursorPillBubbleSizing {
    case intrinsic
    case constrained(maxWidth: CGFloat)
}

struct CursorPillBubble: View {
    let text: String
    let scale: CGFloat
    var opacity: Double = 1.0
    var sizing: CursorPillBubbleSizing = .intrinsic

    /// Zero-width space keeps the Text's intrinsic height stable when the
    /// typewriter starts from empty. Without this the pill would collapse
    /// vertically for the first frame before the first character lands.
    private var displayedText: String {
        text.isEmpty ? " " : text
    }

    var body: some View {
        sizedTextContent
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(DS.Colors.overlayCursorBrand)
                    .shadow(
                        color: DS.Colors.overlayCursorBrand.opacity(0.5 + (1.0 - scale) * 1.0),
                        radius: 6 + (1.0 - scale) * 16,
                        x: 0,
                        y: 0
                    )
            )
            .modifier(CursorPillOuterSizingModifier(sizing: sizing))
            .opacity(opacity)
    }

    @ViewBuilder
    private var sizedTextContent: some View {
        switch sizing {
        case .intrinsic:
            Text(displayedText)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white)
        case .constrained(let maxWidth):
            // Constrain the text frame before the background+padding so the
            // pill wraps on long consent messages instead of running off the
            // edge of the screen. `fixedSize(horizontal: false, vertical: true)`
            // keeps the height hugging the wrapped content.
            Text(displayedText)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white)
                .frame(maxWidth: maxWidth, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Terminator modifier that fixes the intrinsic bubble size once the
/// background has been composed. Only applies in `.intrinsic` mode — the
/// constrained path already locks sizing at the Text level.
private struct CursorPillOuterSizingModifier: ViewModifier {
    let sizing: CursorPillBubbleSizing

    func body(content: Content) -> some View {
        switch sizing {
        case .intrinsic:
            content.fixedSize()
        case .constrained:
            content
        }
    }
}
