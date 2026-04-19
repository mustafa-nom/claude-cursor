//
//  MenuBarPanelManager.swift
//  claude-cursor
//
//  Manages the NSStatusItem (menu bar icon) and a custom borderless NSPanel
//  that drops down below it when clicked. The panel hosts a SwiftUI view
//  (CompanionPanelView) via NSHostingView. Uses the same NSPanel pattern as
//  FloatingSessionButton and GlobalPushToTalkOverlay for consistency.
//
//  The panel is non-activating so it does not steal focus from the user's
//  current app, and auto-dismisses when the user clicks outside.
//

import AppKit
import SwiftUI

extension Notification.Name {
    static let claudeCursorDismissPanel = Notification.Name("claudeCursorDismissPanel")
}

/// Custom NSPanel subclass that can become the key window even with
/// .nonactivatingPanel style, allowing text fields to receive focus.
private class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class MenuBarPanelManager: NSObject {
    private var statusItem: NSStatusItem?
    private var panel: NSPanel?
    private var clickOutsideMonitor: Any?
    private var dismissPanelObserver: NSObjectProtocol?

    private let companionManager: CompanionManager
    private let panelWidth: CGFloat = 320
    private let panelHeight: CGFloat = 380

    init(companionManager: CompanionManager) {
        self.companionManager = companionManager
        super.init()
        createStatusItem()

        dismissPanelObserver = NotificationCenter.default.addObserver(
            forName: .claudeCursorDismissPanel,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.hidePanel()
        }
    }

    deinit {
        if let monitor = clickOutsideMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let observer = dismissPanelObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Status Item

    private func createStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        guard let button = statusItem?.button else { return }

        let menuBarIcon = makeClaudeCursorMenuBarIcon()
        menuBarIcon.isTemplate = false
        button.image = menuBarIcon
        button.action = #selector(statusItemClicked)
        button.target = self
    }

    /// Menu bar image: bundled `claudeCursor` asset (same mark as in-app) tinted
    /// solid white so it reads clearly on the dark menu bar. Falls back to the
    /// legacy rotated triangle if the asset is missing from the bundle.
    private func makeClaudeCursorMenuBarIcon() -> NSImage {
        let iconSideLength: CGFloat = 18
        let whiteSilhouette: NSImage
        if let assetImage = NSImage(named: "claudeCursor") {
            whiteSilhouette = menuBarWhiteSilhouette(from: assetImage, pixelSideLength: iconSideLength)
        } else {
            whiteSilhouette = makeFallbackProgrammaticTriangleMenuBarIcon(sideLength: iconSideLength)
        }
        return menuBarIconImageByApplying45DegreeRotation(
            whiteSilhouette: whiteSilhouette,
            pixelSideLength: iconSideLength
        )
    }

    /// Fills with white then uses the source alpha (`destinationIn`) so the
    /// vector cursor shape becomes a crisp white glyph (not template-tinted).
    private func menuBarWhiteSilhouette(from sourceImage: NSImage, pixelSideLength: CGFloat) -> NSImage {
        let outputImage = NSImage(size: NSSize(width: pixelSideLength, height: pixelSideLength))
        outputImage.lockFocus()
        defer { outputImage.unlockFocus() }

        let destinationRect = NSRect(x: 0, y: 0, width: pixelSideLength, height: pixelSideLength)
        let sourceRect = NSRect(origin: .zero, size: sourceImage.size)

        NSColor.white.setFill()
        destinationRect.fill()

        sourceImage.draw(
            in: destinationRect,
            from: sourceRect,
            operation: .destinationIn,
            fraction: 1.0,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high]
        )

        return outputImage
    }

    /// Rotates the white glyph 45° around the center (sign matches SwiftUI `rotationEffect(.degrees(45))` under flipped `NSImage` drawing).
    /// Slight scale keeps the corners inside the square status-item slot.
    private func menuBarIconImageByApplying45DegreeRotation(
        whiteSilhouette: NSImage,
        pixelSideLength: CGFloat
    ) -> NSImage {
        let outputImage = NSImage(size: NSSize(width: pixelSideLength, height: pixelSideLength))
        outputImage.lockFocus()
        defer { outputImage.unlockFocus() }

        guard let graphicsContext = NSGraphicsContext.current?.cgContext else {
            whiteSilhouette.draw(
                in: NSRect(x: 0, y: 0, width: pixelSideLength, height: pixelSideLength),
                from: NSRect(origin: .zero, size: whiteSilhouette.size),
                operation: .sourceOver,
                fraction: 1.0,
                respectFlipped: true,
                hints: [.interpolation: NSImageInterpolation.high]
            )
            return outputImage
        }

        let side = pixelSideLength
        graphicsContext.saveGState()
        graphicsContext.translateBy(x: side / 2, y: side / 2)
        graphicsContext.scaleBy(x: -1, y: 1)
        graphicsContext.rotate(by: -CGFloat.pi / 4)
        let rotationInsetScale: CGFloat = 0.76
        graphicsContext.scaleBy(x: rotationInsetScale, y: rotationInsetScale)
        graphicsContext.translateBy(x: -side / 2, y: -side / 2)

        let drawRect = NSRect(x: 0, y: 0, width: side, height: side)
        whiteSilhouette.draw(
            in: drawRect,
            from: NSRect(origin: .zero, size: whiteSilhouette.size),
            operation: .sourceOver,
            fraction: 1.0,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high]
        )
        graphicsContext.restoreGState()

        return outputImage
    }

    /// Legacy menu bar mark — simple upward triangle; rotation is applied in
    /// `menuBarIconImageByApplying45DegreeRotation` so it matches the asset path.
    private func makeFallbackProgrammaticTriangleMenuBarIcon(sideLength: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: sideLength, height: sideLength))
        image.lockFocus()
        defer { image.unlockFocus() }

        let triangleSize = sideLength * 0.7
        let cx = sideLength * 0.50
        let cy = sideLength * 0.50
        let height = triangleSize * sqrt(3.0) / 2.0

        let top = CGPoint(x: cx, y: cy + height / 1.5)
        let bottomLeft = CGPoint(x: cx - triangleSize / 2, y: cy - height / 3)
        let bottomRight = CGPoint(x: cx + triangleSize / 2, y: cy - height / 3)

        let path = NSBezierPath()
        path.move(to: top)
        path.line(to: bottomLeft)
        path.line(to: bottomRight)
        path.close()

        NSColor.white.setFill()
        path.fill()

        return image
    }

    /// Opens the panel automatically on app launch so the user sees
    /// permissions and the start button right away.
    func showPanelOnLaunch() {
        // Small delay so the status item has time to appear in the menu bar
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            self.showPanel()
            CompanionPanelSoundFeedback.shared.playEshopSound()
        }
    }

    @objc private func statusItemClicked() {
        if let panel, panel.isVisible {
            hidePanel()
        } else {
            showPanel()
        }
    }

    // MARK: - Panel Lifecycle

    private func showPanel() {
        if panel == nil {
            createPanel()
        }

        positionPanelBelowStatusItem()

        panel?.makeKeyAndOrderFront(nil)
        panel?.orderFrontRegardless()
        installClickOutsideMonitor()

        // Second pass after SwiftUI lays out — avoids a one-frame bad `fittingSize`
        // without opening the panel at a wrong origin.
        DispatchQueue.main.async { [weak self] in
            self?.positionPanelBelowStatusItem()
        }
    }

    private func hidePanel() {
        panel?.orderOut(nil)
        removeClickOutsideMonitor()
    }

    private func createPanel() {
        let companionPanelView = CompanionPanelView(companionManager: companionManager)
            .frame(width: panelWidth)

        let hostingView = NSHostingView(rootView: companionPanelView)
        hostingView.frame = NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear

        let menuBarPanel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        menuBarPanel.isFloatingPanel = true
        menuBarPanel.level = .floating
        menuBarPanel.isOpaque = false
        menuBarPanel.backgroundColor = .clear
        menuBarPanel.hasShadow = false
        menuBarPanel.hidesOnDeactivate = false
        menuBarPanel.isExcludedFromWindowsMenu = true
        menuBarPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        menuBarPanel.isMovableByWindowBackground = false
        menuBarPanel.titleVisibility = .hidden
        menuBarPanel.titlebarAppearsTransparent = true

        menuBarPanel.contentView = hostingView
        panel = menuBarPanel
    }

    private func positionPanelBelowStatusItem() {
        guard let panel else { return }
        guard let buttonWindow = statusItem?.button?.window else { return }

        let statusItemFrame = buttonWindow.frame
        let gapBelowMenuBar: CGFloat = 4

        // Calculate the panel's content height from the hosting view's fitting size
        // so the panel snugly wraps the SwiftUI content instead of using a fixed height.
        // Never trust a near-zero height: before layout settles, `fittingSize` can be
        // tiny and squeezing the window causes NSHostingView constraint thrashing
        // (AppKit NSGenericException on the Update Constraints pass).
        let fittingSize = panel.contentView?.fittingSize ?? CGSize(width: panelWidth, height: panelHeight)
        let actualPanelHeight = max(fittingSize.height, panelHeight)

        // Horizontally center the panel beneath the status item icon
        let panelOriginX = statusItemFrame.midX - (panelWidth / 2)
        let panelOriginY = statusItemFrame.minY - actualPanelHeight - gapBelowMenuBar

        panel.setFrame(
            NSRect(x: panelOriginX, y: panelOriginY, width: panelWidth, height: actualPanelHeight),
            display: true
        )
    }

    // MARK: - Click Outside Dismissal

    /// Installs a global event monitor that hides the panel when the user clicks
    /// anywhere outside it — the same transient dismissal behavior as NSPopover.
    /// Uses a short delay so that system permission dialogs (triggered by Grant
    /// buttons in the panel) don't immediately dismiss the panel when they appear.
    private func installClickOutsideMonitor() {
        removeClickOutsideMonitor()

        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let self, let panel = self.panel else { return }

            // Check if the click is inside the status item button — if so, the
            // statusItemClicked handler will toggle the panel, so don't also hide.
            let clickLocation = NSEvent.mouseLocation
            if panel.frame.contains(clickLocation) {
                return
            }

            // Delay dismissal slightly to avoid closing the panel when
            // a system permission dialog appears (e.g. microphone access).
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                guard panel.isVisible else { return }

                // If permissions aren't all granted yet, a system dialog
                // may have focus — don't dismiss during onboarding.
                if !self.companionManager.allPermissionsGranted && !NSApp.isActive {
                    return
                }

                self.hidePanel()
            }
        }
    }

    private func removeClickOutsideMonitor() {
        if let monitor = clickOutsideMonitor {
            NSEvent.removeMonitor(monitor)
            clickOutsideMonitor = nil
        }
    }
}
