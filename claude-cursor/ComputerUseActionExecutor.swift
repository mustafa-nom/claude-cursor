//
//  ComputerUseActionExecutor.swift
//  claude-cursor
//
//  Maps Claude Computer Use API action responses to local macOS operations
//  via AutomationEngine's CGEvent dispatch + ScreenCaptureKit screenshots.
//  Screenshots are resized to match declared tool dimensions (see ComputerUseImageFormatting).
//

import AppKit
import Foundation

@MainActor
final class ComputerUseActionExecutor {

    private let automationEngine: AutomationEngine
    private let targetNSScreen: NSScreen
    private let runMetrics: ComputerUseRunMetrics
    private let rawDirectoryURL: URL
    private let runIdentifier: String

    let reportedDisplayWidthPixels: Int
    let reportedDisplayHeightPixels: Int

    private let displayFrame: CGRect
    private let actualDisplayWidthPoints: CGFloat
    private let actualDisplayHeightPoints: CGFloat

    private var lastScreenshotPerceptualHash: UInt64?

    init(
        automationEngine: AutomationEngine,
        targetNSScreen: NSScreen,
        runMetrics: ComputerUseRunMetrics,
        rawDirectoryURL: URL,
        runIdentifier: String
    ) {
        self.automationEngine = automationEngine
        self.targetNSScreen = targetNSScreen
        self.runMetrics = runMetrics
        self.rawDirectoryURL = rawDirectoryURL
        self.runIdentifier = runIdentifier

        let resolution = ComputerUseImageFormatting.bestComputerUseResolution(
            forDisplayWidth: Int(targetNSScreen.frame.width),
            displayHeight: Int(targetNSScreen.frame.height)
        )
        self.reportedDisplayWidthPixels = resolution.width
        self.reportedDisplayHeightPixels = resolution.height

        self.displayFrame = targetNSScreen.frame
        self.actualDisplayWidthPoints = targetNSScreen.frame.width
        self.actualDisplayHeightPoints = targetNSScreen.frame.height
    }

    struct ActionResult {
        let screenshotBase64: String?
        let screenshotMediaType: String
        let resultText: String
        let isError: Bool
        /// True when the action was refused because the frontmost app is
        /// on the safety deny-list. The Computer Use loop in `ClaudeAPI`
        /// checks this flag after each action and breaks on first hit —
        /// retrying a deny-listed app never makes sense (it's a protected
        /// target, not a transient failure), so we don't let the loop
        /// burn iterations arguing with a guard rail.
        let wasBlockedByDenyList: Bool
        /// The bundle identifier of the deny-listed app at the time of the
        /// refusal. Surfaced in the status line, JSONL `run_refused`
        /// event, and the final tool result to Claude so the model
        /// understands what it hit.
        let blockedBundleIdentifier: String?

        init(
            screenshotBase64: String?,
            screenshotMediaType: String,
            resultText: String,
            isError: Bool,
            wasBlockedByDenyList: Bool = false,
            blockedBundleIdentifier: String? = nil
        ) {
            self.screenshotBase64 = screenshotBase64
            self.screenshotMediaType = screenshotMediaType
            self.resultText = resultText
            self.isError = isError
            self.wasBlockedByDenyList = wasBlockedByDenyList
            self.blockedBundleIdentifier = blockedBundleIdentifier
        }
    }

    func executeAction(actionDict: [String: Any]) async -> ActionResult {
        let actionType = (actionDict["action"] as? String) ?? ""

        if shouldCheckDenyList(forActionType: actionType) {
            let frontmostBundleIdentifier = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
            if AutomationSafetyPolicy.isBundleIdentifierOnDenyList(frontmostBundleIdentifier) {
                let message = "automation denied: frontmost app \(frontmostBundleIdentifier) is on the safety block list — stop and ask the user to switch apps."
                logRunEvent(eventType: "deny_list_block", payload: [
                    "action": actionType,
                    "bundle_id": frontmostBundleIdentifier,
                ])
                return ActionResult(
                    screenshotBase64: nil,
                    screenshotMediaType: "image/jpeg",
                    resultText: message,
                    isError: true,
                    wasBlockedByDenyList: true,
                    blockedBundleIdentifier: frontmostBundleIdentifier
                )
            }
        }

        let outcome: ActionResult
        switch actionType {
        case "screenshot":
            outcome = await captureScreenshotResult(prefixText: "screenshot captured", actionType: actionType)
        case "left_click":
            outcome = await performClick(
                coordinate: actionDict["coordinate"],
                actionType: actionType,
                click: { [automationEngine] point in
                    automationEngine.dispatchSyntheticMouseClick(atScreenCoordinate: point)
                },
                prefixBuilder: { "clicked at \($0)" }
            )
        case "right_click":
            outcome = await performClick(
                coordinate: actionDict["coordinate"],
                actionType: actionType,
                click: { [automationEngine] point in
                    automationEngine.dispatchSyntheticRightClick(atScreenCoordinate: point)
                },
                prefixBuilder: { "right-clicked at \($0)" }
            )
        case "double_click":
            outcome = await performClick(
                coordinate: actionDict["coordinate"],
                actionType: actionType,
                click: { [automationEngine] point in
                    automationEngine.dispatchSyntheticDoubleClick(atScreenCoordinate: point)
                },
                prefixBuilder: { "double-clicked at \($0)" }
            )
        case "mouse_move":
            guard let coordinate = actionDict["coordinate"] as? [Any], coordinate.count == 2 else {
                return ActionResult(
                    screenshotBase64: nil,
                    screenshotMediaType: "image/jpeg",
                    resultText: "missing coordinate for mouse_move",
                    isError: true
                )
            }
            let screenPoint = convertComputerUseCoordinateToAppKit(coordinate)
            automationEngine.dispatchSyntheticMouseMove(toScreenCoordinate: screenPoint)
            try? await Task.sleep(nanoseconds: 150_000_000)
            outcome = await captureScreenshotResult(prefixText: "moved mouse to \(screenPoint)", actionType: actionType)
        case "type":
            guard let textToType = actionDict["text"] as? String else {
                return ActionResult(
                    screenshotBase64: nil,
                    screenshotMediaType: "image/jpeg",
                    resultText: "missing text for type action",
                    isError: true
                )
            }
            automationEngine.dispatchSyntheticTextInput(textToType: textToType)
            try? await Task.sleep(nanoseconds: 200_000_000)
            outcome = await captureScreenshotResult(
                prefixText: "typed \(textToType.prefix(30))",
                actionType: actionType
            )
        case "key":
            guard let keyCombo = actionDict["text"] as? String else {
                return ActionResult(
                    screenshotBase64: nil,
                    screenshotMediaType: "image/jpeg",
                    resultText: "missing text for key action",
                    isError: true
                )
            }
            automationEngine.dispatchSyntheticKeyboardShortcut(keyCombo: keyCombo)
            try? await Task.sleep(nanoseconds: 300_000_000)
            outcome = await captureScreenshotResult(prefixText: "pressed \(keyCombo)", actionType: actionType)
        case "scroll":
            guard let coordinate = actionDict["coordinate"] as? [Any], coordinate.count == 2 else {
                return ActionResult(
                    screenshotBase64: nil,
                    screenshotMediaType: "image/jpeg",
                    resultText: "missing coordinate for scroll",
                    isError: true
                )
            }
            let directionString = (actionDict["scroll_direction"] as? String) ?? "down"
            let scrollAmount = (actionDict["scroll_amount"] as? Int) ?? 3
            let screenPoint = convertComputerUseCoordinateToAppKit(coordinate)
            let direction = AutomationEngine.ScrollDirection.fromString(directionString)
            automationEngine.dispatchSyntheticScroll(
                atScreenCoordinate: screenPoint,
                scrollDirection: direction,
                scrollAmount: scrollAmount
            )
            try? await Task.sleep(nanoseconds: 300_000_000)
            outcome = await captureScreenshotResult(
                prefixText: "scrolled \(directionString) by \(scrollAmount)",
                actionType: actionType
            )
        case "wait":
            let waitSeconds = (actionDict["duration"] as? Double) ?? 1.0
            let clampedWait = min(waitSeconds, 5.0)
            try? await Task.sleep(nanoseconds: UInt64(clampedWait * 1_000_000_000))
            outcome = await captureScreenshotResult(prefixText: "waited \(clampedWait)s", actionType: actionType)
        default:
            outcome = ActionResult(
                screenshotBase64: nil,
                screenshotMediaType: "image/jpeg",
                resultText: "unsupported action: \(actionType)",
                isError: true
            )
        }

        logRunEvent(eventType: "action_completed", payload: [
            "action": actionType,
            "is_error": outcome.isError,
            "result_prefix": String(outcome.resultText.prefix(120)),
        ])

        return outcome
    }

    private func shouldCheckDenyList(forActionType actionType: String) -> Bool {
        switch actionType {
        case "screenshot", "wait":
            return false
        default:
            return true
        }
    }

    private func performClick(
        coordinate: Any?,
        actionType: String,
        click: (CGPoint) -> Void,
        prefixBuilder: (CGPoint) -> String
    ) async -> ActionResult {
        guard let coordinate = coordinate as? [Any], coordinate.count == 2 else {
            return ActionResult(
                screenshotBase64: nil,
                screenshotMediaType: "image/jpeg",
                resultText: "missing coordinate for \(actionType)",
                isError: true
            )
        }
        let screenPoint = convertComputerUseCoordinateToAppKit(coordinate)
        click(screenPoint)
        try? await Task.sleep(nanoseconds: 300_000_000)
        return await captureScreenshotResult(prefixText: prefixBuilder(screenPoint), actionType: actionType)
    }

    private func convertComputerUseCoordinateToAppKit(_ coordinate: [Any]) -> CGPoint {
        let rawX = (coordinate[0] as? Double) ?? Double(coordinate[0] as? Int ?? 0)
        let rawY = (coordinate[1] as? Double) ?? Double(coordinate[1] as? Int ?? 0)

        let scaleX = actualDisplayWidthPoints / CGFloat(reportedDisplayWidthPixels)
        let scaleY = actualDisplayHeightPoints / CGFloat(reportedDisplayHeightPixels)

        let displayLocalX = CGFloat(rawX) * scaleX
        let displayLocalY = CGFloat(rawY) * scaleY

        let appKitY = actualDisplayHeightPoints - displayLocalY

        return CGPoint(
            x: displayLocalX + displayFrame.origin.x,
            y: appKitY + displayFrame.origin.y
        )
    }

    private func captureScreenshotResult(prefixText: String, actionType: String) async -> ActionResult {
        do {
            let captures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()
            guard let bestCapture = ComputerUseCaptureSelection.bestCapture(
                matchingTargetScreen: targetNSScreen,
                in: captures
            ) else {
                return ActionResult(
                    screenshotBase64: nil,
                    screenshotMediaType: "image/jpeg",
                    resultText: "\(prefixText). screenshot capture returned no screens.",
                    isError: true
                )
            }
            runMetrics.screenshotCount += 1

            guard let resizedJPEG = ComputerUseImageFormatting.jpegDataResizedForComputerUse(
                captureImageData: bestCapture.imageData,
                displayWidthInPoints: Int(actualDisplayWidthPoints),
                displayHeightInPoints: Int(actualDisplayHeightPoints)
            ) else {
                return ActionResult(
                    screenshotBase64: nil,
                    screenshotMediaType: "image/jpeg",
                    resultText: "\(prefixText). failed to resize screenshot for computer use.",
                    isError: true
                )
            }

            let changeResult = ScreenshotDiffDetector.didScreenMeaningfullyChange(
                betweenPreviousHash: lastScreenshotPerceptualHash,
                andCurrentImageData: resizedJPEG
            )
            lastScreenshotPerceptualHash = changeResult.newHash

            runMetrics.registerActionOutcome(
                actionType: actionType,
                screenMeaningfullyChanged: changeResult.didChange
            )

            var message = prefixText
            let actionTypesThatExpectVisualChange = ["left_click", "right_click", "double_click", "scroll", "type", "key"]
            if !changeResult.didChange, actionTypesThatExpectVisualChange.contains(actionType) {
                message += " — note: screen barely changed after this action (possible mis-click, loading UI, or wrong target)."
            }

            let base64 = resizedJPEG.base64EncodedString()
            return ActionResult(
                screenshotBase64: base64,
                screenshotMediaType: "image/jpeg",
                resultText: message,
                isError: false
            )
        } catch {
            return ActionResult(
                screenshotBase64: nil,
                screenshotMediaType: "image/jpeg",
                resultText: "\(prefixText). screenshot capture failed: \(error.localizedDescription)",
                isError: true
            )
        }
    }

    private func logRunEvent(eventType: String, payload: [String: Any]) {
        ComputerUseRunLogger.appendRunEvent(
            wikiRawDirectoryURL: rawDirectoryURL,
            runID: runIdentifier,
            eventType: eventType,
            payload: payload
        )
    }
}
