//
//  AutomationEngine.swift
//  claude-cursor
//
//  CGEvent-based synthetic input dispatcher for guided navigation. Phase F
//  feature — behind an @AppStorage flag and gated by a one-time consent
//  prompt per navigation sequence. When the user approves, the engine
//  executes each AutomationStep against the frontmost app: clicks at a
//  global coordinate, optionally types a short key sequence, captures
//  before/after screenshots, and appends an audit record to
//  `raw/automation-actions.log`. Escape at any time halts the sequence.
//
//  Safety rails (non-negotiable):
//    1. Deny-list: refuse to dispatch into System Settings, Terminal, iTerm2,
//       Keychain Access, or any app whose bundle identifier signals it holds
//       credentials. The deny-list is checked at every step (not just the
//       first) because the user may have switched apps mid-sequence.
//    2. Feature flag: the engine is a no-op unless the user has explicitly
//       enabled experimental automation in the menu bar. Default is off.
//    3. Per-sequence consent: one Y/N prompt at the start covers the entire
//       sequence. Per-action consent was rejected for UX reasons.
//    4. Audit log: every dispatched action is persisted with timestamp,
//       frontmost app, coordinates, and screenshot filenames so the user
//       can inspect what happened after the fact.
//    5. Kill switch: the engine observes `isHaltRequested` between steps.
//       The overlay / menu bar surfaces an Escape handler that flips this
//       flag and the engine exits cleanly without partial dispatch.
//

import AppKit
import Combine
import Foundation

/// Bundle IDs where synthetic input must never run (shared by one-shot automation and Computer Use).
enum AutomationSafetyPolicy {
    static let denyListBundleIdentifiers: Set<String> = [
        "com.apple.systempreferences",
        "com.apple.systemsettings",
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.apple.keychainaccess",
        "com.1password.1password",
        "com.1password.1password7",
        "com.bitwarden.desktop",
        "com.apple.finder-extensions",
        "com.apple.systemuiserver",
    ]

    static func isBundleIdentifierOnDenyList(_ bundleIdentifier: String) -> Bool {
        denyListBundleIdentifiers.contains(bundleIdentifier)
    }
}

// MARK: - Step Model

/// One unit of work in an automation sequence. Today the engine supports
/// two shapes: a mouse click at a global-space coordinate, and an optional
/// short text entry that is typed after the click lands. Keyboard-only
/// steps (no click) can be expressed by setting `screenCoordinate` to nil.
struct AutomationStep {

    /// Human-readable label shown in the audit log and (optionally) spoken
    /// via TTS. Must be non-empty so the audit log is useful.
    let humanReadableLabel: String

    /// Global-space click location in AppKit coordinates (origin = bottom-
    /// left of the primary display). Pass nil to skip the click and only
    /// type text — useful for "type X into the currently focused field"
    /// style steps.
    let screenCoordinate: CGPoint?

    /// Optional short text to type after the click lands. The engine sends
    /// this through a CGEvent keyboard source rather than paste to avoid
    /// clobbering the user's clipboard.
    let textToTypeAfterClick: String?
}

// MARK: - Result

/// Outcome of running an automation sequence. Callers use this to decide
/// whether to report success to the user via TTS, silently move on, or
/// surface an error. `denied` means the frontmost app was on the deny-list
/// at execution time — distinct from `halted` (user pressed Escape).
enum AutomationSequenceResult {
    case completedAllSteps
    case halted(atStepIndex: Int)
    case denied(appBundleIdentifier: String)
    case userRejectedConsent
    case userDidNotRespondToConsent
    case disabledByFlag
}

// MARK: - Consent Outcome

/// Result of asking the user for one-time automation consent. Mapped to
/// distinct tool-result strings upstream so Claude sees different signals
/// for "user said no" vs "user never touched the pill and the prompt
/// timed out".
enum CursorBubbleConsentOutcome {
    case accepted
    case rejectedByUser
    case didNotRespond
}

/// Ensures a consent continuation resumes exactly once. Shared by the
/// timeout Task and the showConsent response callback so whichever path
/// arrives first wins and the other path becomes a no-op.
///
/// `@unchecked Sendable` because both call sites are `@MainActor`-isolated
/// (AutomationEngine is @MainActor; CursorBubbleConsentPromptController
/// fires its callback on main actor), so the mutable state is already
/// serialized by the main actor at runtime.
private final class ConsentResolutionLatch: @unchecked Sendable {
    private var hasResolved = false

    /// Returns true the first time it's called, false on every subsequent
    /// call. Gate `continuation.resume` with this to enforce at-most-once
    /// resolution.
    func markResolved() -> Bool {
        if hasResolved { return false }
        hasResolved = true
        return true
    }
}

// MARK: - Engine

@MainActor
final class AutomationEngine {

    // MARK: Dependencies

    private let consentPromptController: CursorBubbleConsentPromptController
    private let wikiManager: WikiManager

    // MARK: Published State

    /// True while a sequence is dispatching steps. Bindable so the menu bar
    /// panel or overlay can show a "working on it" indicator.
    @Published private(set) var isSequenceRunning: Bool = false

    /// Index of the step currently being executed. Resets to 0 when a new
    /// sequence starts. The overlay reads this to update the "step i of n"
    /// banner alongside the lesson overlay.
    @Published private(set) var currentStepIndex: Int = 0

    /// Flipped to true when the user presses Escape or hits the kill switch.
    /// The engine checks this between steps and aborts mid-sequence.
    @Published var isHaltRequested: Bool = false

    // MARK: Safety Configuration

    /// Delay between dispatching a click and typing text. Gives the target
    /// app time to accept focus and show the text field cursor — without
    /// this, the first few keystrokes sometimes land on a stale field.
    private let postClickToTypePauseSeconds: Double = 0.18

    /// Delay between sequential steps. Short enough to feel responsive,
    /// long enough that animations/transitions in the target app complete
    /// before the next click fires.
    private let interStepPauseSeconds: Double = 0.45

    // MARK: Init

    init(
        consentPromptController: CursorBubbleConsentPromptController,
        wikiManager: WikiManager
    ) {
        self.consentPromptController = consentPromptController
        self.wikiManager = wikiManager
    }

    // MARK: - Public Entry Point

    /// Asks the user for one-time consent and, on approval, dispatches every
    /// step in order. Callers supply a human-readable description of the
    /// whole sequence so the consent prompt is concrete ("Want me to handle
    /// the clicks while I guide you through exporting?") rather than
    /// abstract ("Run automation?").
    ///
    /// The feature flag (`isAutomationExperimentalEnabled`) is checked
    /// BEFORE the consent prompt is shown — disabled flag = silent no-op
    /// so the rest of the pipeline degrades to cursor-pointing only.
    func requestConsentAndRunAutomationSequence(
        sequenceHumanReadableDescription: String,
        automationSteps: [AutomationStep],
        isAutomationExperimentalEnabled: Bool
    ) async -> AutomationSequenceResult {

        guard isAutomationExperimentalEnabled else {
            print("🤖 AutomationEngine: disabled by flag — returning silent no-op")
            return .disabledByFlag
        }

        guard !automationSteps.isEmpty else {
            print("🤖 AutomationEngine: no steps — nothing to run")
            return .completedAllSteps
        }

        let consentOutcome = await requestOneTimeConsent(
            forSequenceDescription: sequenceHumanReadableDescription,
            stepCount: automationSteps.count
        )

        switch consentOutcome {
        case .accepted:
            break
        case .rejectedByUser:
            print("🤖 AutomationEngine: user rejected consent")
            return .userRejectedConsent
        case .didNotRespond:
            print("🤖 AutomationEngine: user did not respond to consent within \(Int(consentTimeoutSeconds))s")
            return .userDidNotRespondToConsent
        }

        isSequenceRunning = true
        isHaltRequested = false
        currentStepIndex = 0
        defer { isSequenceRunning = false }

        for (stepIndex, automationStep) in automationSteps.enumerated() {
            currentStepIndex = stepIndex

            if isHaltRequested {
                print("🤖 AutomationEngine: halted at step \(stepIndex)")
                appendAuditLogLine(
                    lineContent: "HALTED at step \(stepIndex) — user requested stop"
                )
                return .halted(atStepIndex: stepIndex)
            }

            // Re-check the deny-list at every step because the user may have
            // switched apps mid-sequence (cmd-tab, dock click, etc). The
            // deny-list is cheap to check and the cost of a wrong dispatch
            // into Terminal or Keychain is high.
            let currentFrontmostBundleIdentifier = NSWorkspace.shared
                .frontmostApplication?.bundleIdentifier ?? ""
            if AutomationSafetyPolicy.isBundleIdentifierOnDenyList(currentFrontmostBundleIdentifier) {
                print("🤖 AutomationEngine: denied — frontmost app is \(currentFrontmostBundleIdentifier)")
                appendAuditLogLine(
                    lineContent: "DENIED at step \(stepIndex) — frontmost app \(currentFrontmostBundleIdentifier) is on deny-list"
                )
                return .denied(appBundleIdentifier: currentFrontmostBundleIdentifier)
            }

            await executeSingleAutomationStep(
                automationStep: automationStep,
                stepIndex: stepIndex,
                frontmostBundleIdentifier: currentFrontmostBundleIdentifier
            )

            // Pause between steps so the target app can settle (menu
            // animations, modal transitions, etc.) before the next click.
            try? await Task.sleep(nanoseconds: UInt64(interStepPauseSeconds * 1_000_000_000))
        }

        appendAuditLogLine(lineContent: "COMPLETED all \(automationSteps.count) steps")
        return .completedAllSteps
    }

    /// External halt entry point. Overlay Escape-key handler, menu bar
    /// "Stop" button, etc., flip this flag. The engine checks it between
    /// steps and exits cleanly.
    func requestHaltOfCurrentSequence() {
        isHaltRequested = true
    }

    // MARK: - Consent Prompt

    /// Maximum time the user has to accept or decline the consent prompt
    /// before the continuation resumes with `.didNotRespond`. Three minutes
    /// gives a user who walks away time to return without punishing them,
    /// but prevents the Computer Use agent loop from hanging indefinitely.
    private let consentTimeoutSeconds: TimeInterval = 180

    /// Bridges CursorBubbleConsentPromptController's callback-based API to
    /// an async/await consent outcome. Used by the one-shot CGEvent path.
    private func requestOneTimeConsent(
        forSequenceDescription sequenceHumanReadableDescription: String,
        stepCount: Int
    ) async -> CursorBubbleConsentOutcome {
        let consentMessage = """
        want me to handle \(stepCount) \(stepCount == 1 ? "click" : "clicks") \
        for \(sequenceHumanReadableDescription)?
        """
        return await requestConsentOutcome(withMessage: consentMessage)
    }

    /// Public consent entry point for callers that manage their own action
    /// loop (e.g. the Computer Use agent loop). Shows the same terracotta
    /// consent pill as the built-in sequence runner.
    func requestOneTimeConsentAsync(
        sequenceHumanReadableDescription: String
    ) async -> CursorBubbleConsentOutcome {
        let consentMessage = """
        want me to automate this for \(sequenceHumanReadableDescription)?
        """
        return await requestConsentOutcome(withMessage: consentMessage)
    }

    /// Shows the consent pill and waits for the user to tap Yes/No, or
    /// returns `.didNotRespond` after `consentTimeoutSeconds` elapses.
    /// The latch guarantees the continuation resumes exactly once
    /// regardless of which path arrives first. On timeout, the controller
    /// swaps the pill content to "timed out — dismissing" for 3 seconds
    /// before hiding the panel so the user can see why it disappeared.
    private func requestConsentOutcome(
        withMessage consentMessage: String
    ) async -> CursorBubbleConsentOutcome {
        let resolutionLatch = ConsentResolutionLatch()
        let timeoutSecondsValue = consentTimeoutSeconds
        // Capture the controller reference locally so the `@Sendable`
        // onCancel handler (which may fire off-main-actor) can route a
        // dismissal back onto main actor without touching @MainActor-
        // isolated `self` from a non-isolated context.
        let consentPromptController = self.consentPromptController

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let timeoutTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(timeoutSecondsValue))
                    guard !Task.isCancelled else { return }
                    guard resolutionLatch.markResolved() else {
                        // Another path already resolved — debug-only signal
                        // so a future regression where two paths race to
                        // resolve surfaces during development.
                        assertionFailure(
                            "ConsentResolutionLatch double-resolve attempt from timeout path"
                        )
                        return
                    }
                    self?.consentPromptController.beginTimeoutDismissal()
                    continuation.resume(returning: .didNotRespond)
                }

                consentPromptController.showConsent(
                    withMessage: consentMessage,
                    onResponse: { outcome in
                        guard resolutionLatch.markResolved() else {
                            assertionFailure(
                                "ConsentResolutionLatch double-resolve attempt from response path"
                            )
                            return
                        }
                        timeoutTask.cancel()
                        continuation.resume(returning: outcome)
                    }
                )
            }
        } onCancel: {
            // Parent Task was cancelled (e.g. Computer Use loop torn down).
            // The outer `withCheckedContinuation` will resolve through
            // whichever existing path wins the latch; our job here is to
            // tear the pill down so the user doesn't see an orphaned
            // prompt after the enclosing work was abandoned.
            Task { @MainActor in
                consentPromptController.dismissPrompt()
            }
        }
    }

    // MARK: - Single Step Execution

    /// Runs one step: captures a before screenshot, dispatches the click
    /// and any keyboard input, captures an after screenshot, and records
    /// the whole thing in the audit log. Any failure is logged but does not
    /// throw — we'd rather record a partial trail than blow up the sequence.
    private func executeSingleAutomationStep(
        automationStep: AutomationStep,
        stepIndex: Int,
        frontmostBundleIdentifier: String
    ) async {
        let isoTimestamp = ISO8601DateFormatter.sharedInternetDateTime.string(from: Date())
        let sanitizedStepLabel = sanitizeLabelForFilename(automationStep.humanReadableLabel)
        let beforeScreenshotFilename = "\(isoTimestamp)_step\(stepIndex)_\(sanitizedStepLabel)_before.jpg"
        let afterScreenshotFilename = "\(isoTimestamp)_step\(stepIndex)_\(sanitizedStepLabel)_after.jpg"

        await captureAndSaveAuditScreenshot(filename: beforeScreenshotFilename)

        if let clickLocation = automationStep.screenCoordinate {
            dispatchSyntheticMouseClick(atScreenCoordinate: clickLocation)
        }

        if let textToType = automationStep.textToTypeAfterClick,
           !textToType.isEmpty {
            try? await Task.sleep(nanoseconds: UInt64(postClickToTypePauseSeconds * 1_000_000_000))
            dispatchSyntheticTextInput(textToType: textToType)
        }

        // Small pause before the after-screenshot so the app has time to
        // redraw in response to the click (menu opens, dialog appears, etc).
        try? await Task.sleep(nanoseconds: UInt64(postClickToTypePauseSeconds * 1_000_000_000))

        await captureAndSaveAuditScreenshot(filename: afterScreenshotFilename)

        appendAuditLogLine(lineContent: """
        STEP \(stepIndex): "\(automationStep.humanReadableLabel)" \
        app=\(frontmostBundleIdentifier) \
        coord=\(automationStep.screenCoordinate.map { "(\(Int($0.x)),\(Int($0.y)))" } ?? "nil") \
        typed=\(automationStep.textToTypeAfterClick?.count ?? 0)chars \
        before=\(beforeScreenshotFilename) \
        after=\(afterScreenshotFilename)
        """)
    }

    // MARK: - CGEvent Dispatch

    /// Synthesizes a left mouse down + mouse up at the given global AppKit
    /// coordinate. CGEvent uses Quartz space (origin = top-left) so we flip
    /// the Y axis against the primary display's height before dispatching.
    func dispatchSyntheticMouseClick(atScreenCoordinate globalAppKitCoordinate: CGPoint) {
        dispatchSyntheticMouseEvent(
            atScreenCoordinate: globalAppKitCoordinate,
            downType: .leftMouseDown,
            upType: .leftMouseUp,
            button: .left,
            clickCount: 1
        )
    }

    func dispatchSyntheticRightClick(atScreenCoordinate globalAppKitCoordinate: CGPoint) {
        dispatchSyntheticMouseEvent(
            atScreenCoordinate: globalAppKitCoordinate,
            downType: .rightMouseDown,
            upType: .rightMouseUp,
            button: .right,
            clickCount: 1
        )
    }

    func dispatchSyntheticDoubleClick(atScreenCoordinate globalAppKitCoordinate: CGPoint) {
        dispatchSyntheticMouseEvent(
            atScreenCoordinate: globalAppKitCoordinate,
            downType: .leftMouseDown,
            upType: .leftMouseUp,
            button: .left,
            clickCount: 2
        )
    }

    private func dispatchSyntheticMouseEvent(
        atScreenCoordinate globalAppKitCoordinate: CGPoint,
        downType: CGEventType,
        upType: CGEventType,
        button: CGMouseButton,
        clickCount: Int
    ) {
        let quartzCoordinate = convertAppKitToQuartzCoordinate(
            appKitCoordinate: globalAppKitCoordinate
        )

        let eventSource = CGEventSource(stateID: .hidSystemState)

        let mouseDownEvent = CGEvent(
            mouseEventSource: eventSource,
            mouseType: downType,
            mouseCursorPosition: quartzCoordinate,
            mouseButton: button
        )
        mouseDownEvent?.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))
        mouseDownEvent?.post(tap: .cghidEventTap)

        let mouseUpEvent = CGEvent(
            mouseEventSource: eventSource,
            mouseType: upType,
            mouseCursorPosition: quartzCoordinate,
            mouseButton: button
        )
        mouseUpEvent?.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))
        mouseUpEvent?.post(tap: .cghidEventTap)
    }

    func dispatchSyntheticMouseMove(toScreenCoordinate globalAppKitCoordinate: CGPoint) {
        let quartzCoordinate = convertAppKitToQuartzCoordinate(
            appKitCoordinate: globalAppKitCoordinate
        )
        let eventSource = CGEventSource(stateID: .hidSystemState)
        let moveEvent = CGEvent(
            mouseEventSource: eventSource,
            mouseType: .mouseMoved,
            mouseCursorPosition: quartzCoordinate,
            mouseButton: .left
        )
        moveEvent?.post(tap: .cghidEventTap)
    }

    /// Dispatches a scroll wheel event. Positive `amount` scrolls down/right,
    /// negative scrolls up/left.
    func dispatchSyntheticScroll(
        atScreenCoordinate globalAppKitCoordinate: CGPoint,
        scrollDirection: ScrollDirection,
        scrollAmount: Int
    ) {
        let quartzCoordinate = convertAppKitToQuartzCoordinate(
            appKitCoordinate: globalAppKitCoordinate
        )
        let eventSource = CGEventSource(stateID: .hidSystemState)

        // Move the mouse to the target position first so scroll happens there.
        let moveEvent = CGEvent(
            mouseEventSource: eventSource,
            mouseType: .mouseMoved,
            mouseCursorPosition: quartzCoordinate,
            mouseButton: .left
        )
        moveEvent?.post(tap: .cghidEventTap)

        let verticalDelta: Int32 = scrollDirection.isVertical
            ? Int32(scrollDirection.signedAmount(scrollAmount))
            : 0
        let horizontalDelta: Int32 = scrollDirection.isHorizontal
            ? Int32(scrollDirection.signedAmount(scrollAmount))
            : 0

        let scrollEvent = CGEvent(
            scrollWheelEvent2Source: eventSource,
            units: .line,
            wheelCount: 1,
            wheel1: verticalDelta,
            wheel2: 0,
            wheel3: 0
        )
        if horizontalDelta != 0 {
            scrollEvent?.setIntegerValueField(
                .scrollWheelEventDeltaAxis2,
                value: Int64(horizontalDelta)
            )
        }
        scrollEvent?.post(tap: .cghidEventTap)
    }

    enum ScrollDirection {
        case up, down, left, right

        var isVertical: Bool { self == .up || self == .down }
        var isHorizontal: Bool { self == .left || self == .right }

        func signedAmount(_ amount: Int) -> Int {
            switch self {
            case .down, .right: return -amount
            case .up, .left: return amount
            }
        }

        static func fromString(_ string: String) -> ScrollDirection {
            switch string.lowercased() {
            case "up": return .up
            case "down": return .down
            case "left": return .left
            case "right": return .right
            default: return .down
            }
        }
    }

    /// Dispatches a keyboard shortcut like "ctrl+s", "command+shift+p", etc.
    /// Parses modifier names and the final key character.
    func dispatchSyntheticKeyboardShortcut(keyCombo: String) {
        let eventSource = CGEventSource(stateID: .hidSystemState)
        let parts = keyCombo.lowercased().split(separator: "+").map { String($0).trimmingCharacters(in: .whitespaces) }

        var modifierFlags: CGEventFlags = []
        var keyCharacter: String?

        for part in parts {
            switch part {
            case "ctrl", "control": modifierFlags.insert(.maskControl)
            case "alt", "option": modifierFlags.insert(.maskAlternate)
            case "shift": modifierFlags.insert(.maskShift)
            case "cmd", "command", "super": modifierFlags.insert(.maskCommand)
            default: keyCharacter = part
            }
        }

        guard let finalKey = keyCharacter, !finalKey.isEmpty else { return }

        if finalKey == "return" || finalKey == "enter" {
            dispatchSyntheticReturnKeyPress(modifierFlags: modifierFlags)
            return
        }

        let unicodeScalars = Array(finalKey.utf16)

        let keyDown = CGEvent(keyboardEventSource: eventSource, virtualKey: 0, keyDown: true)
        keyDown?.keyboardSetUnicodeString(stringLength: unicodeScalars.count, unicodeString: unicodeScalars)
        keyDown?.flags = modifierFlags
        keyDown?.post(tap: .cghidEventTap)

        let keyUp = CGEvent(keyboardEventSource: eventSource, virtualKey: 0, keyDown: false)
        keyUp?.keyboardSetUnicodeString(stringLength: unicodeScalars.count, unicodeString: unicodeScalars)
        keyUp?.flags = modifierFlags
        keyUp?.post(tap: .cghidEventTap)
    }

    /// Primary Return key on US/INTL Mac keyboards — matches keycode 36 used in consent UI handling.
    func dispatchSyntheticReturnKeyPress(modifierFlags: CGEventFlags = []) {
        let eventSource = CGEventSource(stateID: .hidSystemState)
        let returnVirtualKey: CGKeyCode = 36
        guard let keyDown = CGEvent(keyboardEventSource: eventSource, virtualKey: returnVirtualKey, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: eventSource, virtualKey: returnVirtualKey, keyDown: false) else {
            return
        }
        keyDown.flags = modifierFlags
        keyUp.flags = modifierFlags
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }

    /// Types a short text string one character at a time via
    /// `CGEvent.keyboardSetUnicodeString`. Paste would be faster but would
    /// clobber the user's clipboard — synthetic keyboard input is slower
    /// but leaves the pasteboard untouched.
    func dispatchSyntheticTextInput(textToType: String) {
        let eventSource = CGEventSource(stateID: .hidSystemState)

        for character in textToType {
            let unicodeScalars = Array(String(character).utf16)
            let keyDownEvent = CGEvent(
                keyboardEventSource: eventSource,
                virtualKey: 0,
                keyDown: true
            )
            keyDownEvent?.keyboardSetUnicodeString(
                stringLength: unicodeScalars.count,
                unicodeString: unicodeScalars
            )
            keyDownEvent?.post(tap: .cghidEventTap)

            let keyUpEvent = CGEvent(
                keyboardEventSource: eventSource,
                virtualKey: 0,
                keyDown: false
            )
            keyUpEvent?.keyboardSetUnicodeString(
                stringLength: unicodeScalars.count,
                unicodeString: unicodeScalars
            )
            keyUpEvent?.post(tap: .cghidEventTap)
        }
    }

    /// Flips the Y axis from AppKit (origin bottom-left) to Quartz (origin
    /// top-left) using the primary display's height. CGEvent posting wants
    /// Quartz coordinates, so every click location the overlay stores in
    /// AppKit space must be converted before dispatch.
    func convertAppKitToQuartzCoordinate(appKitCoordinate: CGPoint) -> CGPoint {
        let primaryDisplayHeight = NSScreen.screens
            .first { $0.frame.origin == .zero }?
            .frame
            .height
            ?? NSScreen.main?.frame.height
            ?? 0
        return CGPoint(
            x: appKitCoordinate.x,
            y: primaryDisplayHeight - appKitCoordinate.y
        )
    }

    // MARK: - Audit Log

    /// Appends a single plain-text line to `raw/automation-actions.log`.
    /// Creates the file if it doesn't exist. Best-effort — a failed write
    /// is logged to the console but doesn't abort the sequence.
    private func appendAuditLogLine(lineContent: String) {
        let auditLogFileURL = wikiManager.rawDirectoryURL
            .appendingPathComponent("automation-actions.log")

        let isoTimestamp = ISO8601DateFormatter.sharedInternetDateTime.string(from: Date())
        let fullLineContent = "[\(isoTimestamp)] \(lineContent)\n"

        guard let lineData = fullLineContent.data(using: .utf8) else { return }

        if FileManager.default.fileExists(atPath: auditLogFileURL.path) {
            do {
                let fileHandle = try FileHandle(forWritingTo: auditLogFileURL)
                defer { try? fileHandle.close() }
                try fileHandle.seekToEnd()
                try fileHandle.write(contentsOf: lineData)
            } catch {
                print("⚠️ AutomationEngine: audit append failed — \(error)")
            }
        } else {
            try? lineData.write(to: auditLogFileURL)
        }
    }

    /// Captures the whole current display and writes a JPEG to
    /// `raw/automation-screenshots/<filename>`. The filename encodes the
    /// step index and label so the audit log references are unambiguous.
    private func captureAndSaveAuditScreenshot(filename: String) async {
        let screenshotDirectoryURL = wikiManager.rawDirectoryURL
            .appendingPathComponent("automation-screenshots", isDirectory: true)

        try? FileManager.default.createDirectory(
            at: screenshotDirectoryURL,
            withIntermediateDirectories: true
        )

        do {
            let screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()
            guard let primaryCapture = screenCaptures.first else { return }
            let destinationURL = screenshotDirectoryURL
                .appendingPathComponent(filename)
            try primaryCapture.imageData.write(to: destinationURL)
        } catch {
            print("⚠️ AutomationEngine: audit screenshot failed — \(error)")
        }
    }

    // MARK: - Helpers

    /// Replaces characters that are problematic in filenames (slashes,
    /// colons, whitespace) with underscores. Keeps the label readable so
    /// audit log files are still greppable by human eyes.
    private func sanitizeLabelForFilename(_ rawLabel: String) -> String {
        let allowedCharacterSet = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let sanitized = rawLabel.unicodeScalars
            .map { allowedCharacterSet.contains($0) ? String($0) : "_" }
            .joined()
        return String(sanitized.prefix(40))
    }
}

// MARK: - Shared ISO8601 Formatter

private extension ISO8601DateFormatter {
    /// Shared formatter with a consistent configuration. ISO8601DateFormatter
    /// is thread-safe per Apple docs, so sharing avoids repeated allocation.
    static let sharedInternetDateTime: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
