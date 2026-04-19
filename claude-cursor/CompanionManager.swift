//
//  CompanionManager.swift
//  claude-cursor
//
//  Central state manager for the companion voice mode. Owns the push-to-talk
//  pipeline (dictation manager + global shortcut monitor + overlay) and
//  exposes observable voice state for the panel UI.
//

import AVFoundation
import Combine
import Foundation
import PostHog
import ScreenCaptureKit
import SwiftUI

enum CompanionVoiceState {
    case idle
    case listening
    case processing
    case responding
}

/// Pure helper so end-of-turn TTS does not repeat the explainer overview already spoken in parallel.
enum ExplainerSpokenTextDedup {
    static func remainingAssistantTextAfterOverviewIfRedundant(
        fullAssistantText: String,
        explainerOverview: String
    ) -> String {
        let fullTrim = fullAssistantText.trimmingCharacters(in: .whitespacesAndNewlines)
        let overTrim = explainerOverview.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !overTrim.isEmpty else { return fullTrim }

        var fullCharacterIndex = fullTrim.startIndex
        var overviewCharacterIndex = overTrim.startIndex

        while overviewCharacterIndex < overTrim.endIndex {
            while fullCharacterIndex < fullTrim.endIndex, fullTrim[fullCharacterIndex].isWhitespace {
                fullCharacterIndex = fullTrim.index(after: fullCharacterIndex)
            }
            while overviewCharacterIndex < overTrim.endIndex, overTrim[overviewCharacterIndex].isWhitespace {
                overviewCharacterIndex = overTrim.index(after: overviewCharacterIndex)
            }
            if overviewCharacterIndex == overTrim.endIndex {
                break
            }
            guard fullCharacterIndex < fullTrim.endIndex else { return fullTrim }

            let fullCodeUnit = fullTrim[fullCharacterIndex]
            let overviewCodeUnit = overTrim[overviewCharacterIndex]
            guard String(fullCodeUnit).lowercased() == String(overviewCodeUnit).lowercased() else {
                return fullTrim
            }
            fullCharacterIndex = fullTrim.index(after: fullCharacterIndex)
            overviewCharacterIndex = overTrim.index(after: overviewCharacterIndex)
        }

        while fullCharacterIndex < fullTrim.endIndex, fullTrim[fullCharacterIndex].isWhitespace {
            fullCharacterIndex = fullTrim.index(after: fullCharacterIndex)
        }

        if fullCharacterIndex < fullTrim.endIndex {
            let punctuationStrippedStart: String.Index = {
                let ch = fullTrim[fullCharacterIndex]
                if ch == "." || ch == "," || ch == ";" || ch == ":" || ch == "—" || ch == "-" {
                    var nextIndex = fullTrim.index(after: fullCharacterIndex)
                    while nextIndex < fullTrim.endIndex, fullTrim[nextIndex].isWhitespace {
                        nextIndex = fullTrim.index(after: nextIndex)
                    }
                    return nextIndex
                }
                return fullCharacterIndex
            }()
            let remainder = String(fullTrim[punctuationStrippedStart...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return remainder
        }
        return ""
    }
}

@MainActor
final class CompanionManager: ObservableObject {
    @Published private(set) var voiceState: CompanionVoiceState = .idle
    @Published private(set) var lastTranscript: String?
    @Published private(set) var currentAudioPowerLevel: CGFloat = 0
    @Published private(set) var hasAccessibilityPermission = false
    @Published private(set) var hasScreenRecordingPermission = false
    @Published private(set) var hasMicrophonePermission = false
    @Published private(set) var hasScreenContentPermission = false

    /// A single UI element Claude has asked the companion to point at.
    /// Multiple targets can be active simultaneously so one response can
    /// light up several on-screen locations at once (e.g. "click File,
    /// then Export"). The first target in `activePointingTargets` is
    /// treated as the "primary" — the buddy flies to it and shows a
    /// speech bubble. Any additional targets render as stationary
    /// secondary markers (`PointingTargetMarker` in `OverlayWindow`).
    struct PointingTarget: Identifiable, Equatable {
        let id = UUID()
        /// Global AppKit-space point (bottom-left origin).
        let screenLocation: CGPoint
        /// Frame of the screen this target belongs to.
        let displayFrame: CGRect
        /// Text for the speech bubble. Empty string falls back to a
        /// random pointer phrase on the primary target.
        let labelText: String
    }

    /// Ordered list of currently-active pointing targets. Set in a single
    /// assignment (not progressive appends) so SwiftUI observers see one
    /// batched change per turn. Cleared when the buddy returns to the
    /// cursor or when a new turn begins.
    @Published var activePointingTargets: [PointingTarget] = []

    // MARK: - Multi-Cursor Explainer

    enum ExplainerPriority: Int, Comparable, CaseIterable {
        case critical = 3
        case important = 2
        case helpful = 1

        static func < (lhs: ExplainerPriority, rhs: ExplainerPriority) -> Bool {
            lhs.rawValue < rhs.rawValue
        }

        /// Maps a JSON string from the tool call to a priority level.
        static func fromString(_ string: String) -> ExplainerPriority {
            switch string.lowercased() {
            case "critical": return .critical
            case "important": return .important
            default: return .helpful
            }
        }

        /// Color indices within `DS.Colors.explainerCursorColors` for this tier.
        var colorIndices: [Int] {
            switch self {
            case .critical: return [0, 1]
            case .important: return [2, 3, 4]
            case .helpful: return [5, 6, 7]
            }
        }
    }

    struct ExplainerElement: Identifiable, Equatable {
        let id = UUID()
        let screenLocation: CGPoint
        let displayFrame: CGRect
        let labelText: String
        let descriptionText: String
        let priority: ExplainerPriority
        let assignedColor: Color

        static func == (lhs: ExplainerElement, rhs: ExplainerElement) -> Bool {
            lhs.id == rhs.id
        }
    }

    struct ExplainerCursorGroup {
        let elements: [ExplainerElement]
        let spokenOverview: String
        let createdAt: Date
    }

    @Published var activeExplainerCursorGroup: ExplainerCursorGroup?
    @Published var isExplainerGroupReturning: Bool = false
    private var explainerAutoDismissTask: Task<Void, Never>?
    /// Overview string from the current turn's explainer tool — used to strip duplicate narration from end-of-turn TTS.
    private var explainerOverviewRawForDedupThisTurn: String?
    private var explainerOverviewSpeechTask: Task<Void, Never>?

    /// Global AppKit-space location of the *primary* pointing target (the
    /// buddy flies to this one). Computed from `activePointingTargets`
    /// so existing call sites — BlueCursorView's `onChange`, the transient-
    /// hide idle poll — keep working unchanged.
    var detectedElementScreenLocation: CGPoint? {
        activePointingTargets.first?.screenLocation
    }

    /// Display frame of the screen hosting the primary pointing target.
    /// Used by BlueCursorView to decide which per-screen overlay should
    /// run the flight animation.
    var detectedElementDisplayFrame: CGRect? {
        activePointingTargets.first?.displayFrame
    }

    /// Custom speech-bubble text for the primary pointing target. When
    /// nil/empty, BlueCursorView falls back to a random pointer phrase.
    var detectedElementBubbleText: String? {
        guard let firstLabel = activePointingTargets.first?.labelText,
              !firstLabel.isEmpty else { return nil }
        return firstLabel
    }

    // MARK: - Onboarding Video State (shared across all screen overlays)

    @Published var onboardingVideoPlayer: AVPlayer?
    @Published var showOnboardingVideo: Bool = false
    @Published var onboardingVideoOpacity: Double = 0.0
    private var onboardingVideoEndObserver: NSObjectProtocol?
    private var onboardingDemoTimeObserver: Any?

    // MARK: - Onboarding Prompt Bubble

    /// Text streamed character-by-character on the cursor after the onboarding video ends.
    @Published var onboardingPromptText: String = ""
    @Published var onboardingPromptOpacity: Double = 0.0
    @Published var showOnboardingPrompt: Bool = false

    // MARK: - Onboarding Music

    private var onboardingMusicPlayer: AVAudioPlayer?
    private var onboardingMusicFadeTimer: Timer?

    let buddyDictationManager = BuddyDictationManager()
    let globalPushToTalkShortcutMonitor = GlobalPushToTalkShortcutMonitor()
    let overlayWindowManager = OverlayWindowManager()
    // The floating response overlay was removed. Spoken output now routes
    // through TTS, the answer panel, and pointer labels only.

    /// Base URL for the Cloudflare Worker proxy. All API requests route
    /// through this so keys never ship in the app binary.
    private static let workerBaseURL = "https://cc-proxy.musnom.workers.dev"

    private(set) lazy var claudeAPI: ClaudeAPI = {
        return ClaudeAPI(proxyURL: "\(Self.workerBaseURL)/chat", model: selectedModel)
    }()

    private lazy var elevenLabsTTSClient: ElevenLabsTTSClient = {
        return ElevenLabsTTSClient(proxyURL: "\(Self.workerBaseURL)/tts")
    }()

    /// Conversation history so Claude remembers prior exchanges within a session.
    /// Each entry is the user's transcript and Claude's response. Published so
    /// the chat transcript view can display the full conversation.
    @Published private(set) var conversationHistory: [(userTranscript: String, assistantResponse: String)] = []

    /// The currently running AI response task, if any. Cancelled when the user
    /// speaks again so a new response can begin immediately.
    private var currentResponseTask: Task<Void, Never>?

    private var shortcutTransitionCancellable: AnyCancellable?
    private var voiceStateCancellable: AnyCancellable?
    private var audioPowerCancellable: AnyCancellable?
    /// Local-event Escape-key monitor, active only while an automation
    /// sequence is running. Pressing Escape flips the engine's halt flag so
    /// the in-flight sequence aborts between steps.
    private var automationEscapeKeyMonitor: Any?
    /// Binding that enables/disables the Escape monitor based on the
    /// engine's running state so we don't intercept Escape during normal
    /// app use.
    private var automationRunningStateCancellable: AnyCancellable?
    private var accessibilityCheckTimer: Timer?
    private var pendingKeyboardShortcutStartTask: Task<Void, Never>?
    /// Scheduled hide for transient cursor mode — cancelled if the user
    /// speaks again before the delay elapses.
    private var transientHideTask: Task<Void, Never>?

    /// The polling task that watches for post-navigation screen changes so
    /// the companion can speak the next step proactively without waiting
    /// for another push-to-talk. Cancelled when the user speaks again,
    /// tutor mode toggles, a new navigation response arrives, or the
    /// 20-second observation window elapses.
    private var pendingNavigationObservationTask: Task<Void, Never>?

    /// Task that sends the current lesson step to Claude with a screenshot
    /// so it can call `point_at_element` on the relevant UI element.
    /// Cancelled on rapid step changes or when the lesson ends.
    private var lessonStepPointingTask: Task<Void, Never>?

    /// The perceptual hash of the last screenshot captured during a
    /// pending-navigation observation cycle. Used to suppress redundant
    /// Claude calls when the screen hasn't meaningfully changed.
    private var lastPendingNavigationScreenshotHash: UInt64?

    /// The most recent transcript and assistant response that triggered
    /// the pending-navigation observation. The polling loop reuses them
    /// as conversation context when asking Claude for the next step.
    private var pendingNavigationUserTranscript: String = ""
    private var pendingNavigationAssistantResponse: String = ""
    /// Monotonic ID for coordinating "point_at_element" verification waits.
    /// Tool execution increments this before publishing a new primary target.
    private var nextPrimaryPointingArrivalWaitID: Int = 0
    /// The wait ID currently expecting a forward-flight arrival signal.
    private var awaitingPrimaryPointingArrivalWaitID: Int?
    /// Latest wait ID whose arrival signal has already fired.
    private var latestSignaledPrimaryPointingArrivalWaitID: Int = 0
    /// Continuation resumed when BlueCursorView reaches the pointing target.
    private var primaryPointingArrivalContinuation: CheckedContinuation<Bool, Never>?

    /// True when all three required permissions (accessibility, screen recording,
    /// microphone) are granted. Used by the panel to show a single "all good" state.
    var allPermissionsGranted: Bool {
        hasAccessibilityPermission && hasScreenRecordingPermission && hasMicrophonePermission && hasScreenContentPermission
    }

    /// Whether the blue cursor overlay is currently visible on screen.
    /// Used by the panel to show accurate status text ("Active" vs "Ready").
    @Published private(set) var isOverlayVisible: Bool = false

    /// The Claude model used for voice responses. Persisted to UserDefaults.
    @Published var selectedModel: String = UserDefaults.standard.string(forKey: "selectedClaudeModel") ?? "claude-sonnet-4-6"

    func setSelectedModel(_ model: String) {
        selectedModel = model
        UserDefaults.standard.set(model, forKey: "selectedClaudeModel")
        claudeAPI.model = model
    }

    /// User preference for whether the ClaudeCursor cursor should be shown.
    /// When toggled off, the overlay is hidden and push-to-talk is disabled.
    /// Persisted to UserDefaults so the choice survives app restarts.
    @Published var isClaudeCursorEnabled: Bool = UserDefaults.standard.object(forKey: "isClaudeCursorEnabled") == nil
        ? true
        : UserDefaults.standard.bool(forKey: "isClaudeCursorEnabled")

    /// Whether ClaudeCursor is in tutor mode — proactively guiding the user
    /// through whatever software they're using by periodically screenshotting
    /// and sending observations to Claude.
    @Published var isTutorModeEnabled: Bool = UserDefaults.standard.bool(forKey: "isTutorModeEnabled")

    func setTutorModeEnabled(_ enabled: Bool) {
        isTutorModeEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "isTutorModeEnabled")
        if enabled {
            startTutorIdleObservation()
        } else {
            stopTutorIdleObservation()
        }
    }

    func setClaudeCursorEnabled(_ enabled: Bool) {
        isClaudeCursorEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "isClaudeCursorEnabled")
        transientHideTask?.cancel()
        transientHideTask = nil

        if enabled {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        } else {
            overlayWindowManager.hideOverlay()
            isOverlayVisible = false
        }
    }

    /// Whether ClaudeCursor's responses are automatically copied to the clipboard.
    /// Defaults to OFF. Persisted to UserDefaults.
    @Published var isAutoCopyResponseEnabled: Bool = UserDefaults.standard.bool(forKey: "isAutoCopyResponseEnabled")

    func setAutoCopyResponseEnabled(_ enabled: Bool) {
        isAutoCopyResponseEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "isAutoCopyResponseEnabled")
    }

    /// Whether wiki knowledge is included in Claude's context for answers
    /// and tutor observations. Defaults to OFF until the wiki pipeline is built.
    @Published var isWikiKnowledgeEnabled: Bool = UserDefaults.standard.bool(forKey: "isWikiKnowledgeEnabled")

    func setWikiKnowledgeEnabled(_ enabled: Bool) {
        isWikiKnowledgeEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "isWikiKnowledgeEnabled")
    }

    /// Whether the chat transcript window is visible. Defaults to OFF.
    @Published var isShowChatEnabled: Bool = UserDefaults.standard.bool(forKey: "isShowChatEnabled")

    func setShowChatEnabled(_ enabled: Bool) {
        isShowChatEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "isShowChatEnabled")
        if enabled {
            chatWindowController.showChatPanel()
        } else {
            chatWindowController.hideChatPanel()
        }
    }

    /// URL for the follow-along YouTube tutorial. When set and started,
    /// the app enters lesson mode with step-by-step overlay guidance.
    @Published var followAlongTutorialURL: String = ""

    /// Whether the user has completed onboarding at least once. Persisted
    /// to UserDefaults so the Start button only appears on first launch.
    var hasCompletedOnboarding: Bool {
        get { UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") }
        set { UserDefaults.standard.set(newValue, forKey: "hasCompletedOnboarding") }
    }

    func start() {
        refreshAllPermissions()
        print("🔑 ClaudeCursor start — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission), onboarded: \(hasCompletedOnboarding)")
        startPermissionPolling()
        bindVoiceStateObservation()
        bindAudioPowerLevel()
        bindShortcutTransitions()
        bindAnswerPanelModeObservation()

        // Open the pattern database up front so rate-limit queries are
        // ready by the time the first tutor idle-observation fires.
        isPatternDatabaseOpen = patternDatabase.open()

        // Initialize the wiki directory structure so page reads and context
        // bundle lookups during tutor observations don't race with setup.
        wikiManager.initializeIfNeeded()
        // Eagerly touch the Claude API so its TLS warmup handshake completes
        // well before the onboarding demo fires at ~40s into the video.
        _ = claudeAPI

        // If the user already completed onboarding AND all permissions are
        // still granted, show the cursor overlay immediately. If permissions
        // were revoked (e.g. signing change), don't show the cursor — the
        // panel will show the permissions UI instead.
        if hasCompletedOnboarding && allPermissionsGranted && isClaudeCursorEnabled {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        }

        // Resume tutor mode if it was previously enabled
        if isTutorModeEnabled {
            startTutorIdleObservation()
        }

        // If the user has been away long enough, generate a warm recap of
        // their last session. The recap is surfaced by the overlay on the
        // next interaction — it's a nice-to-have, never a blocker, so any
        // failure (missing file, Claude error) simply leaves the recap nil.
        Task { [weak self] in
            await self?.generateColdStartRecapIfEligible()
        }

        // Wire the Escape kill switch for automation sequences. The
        // monitor is attached only while a sequence is running so we don't
        // swallow Escape during normal app use (which other controllers
        // use to close panels).
        automationRunningStateCancellable = automationEngine.$isSequenceRunning
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isRunning in
                self?.updateAutomationEscapeKeyMonitor(enable: isRunning)
            }

        startSessionIdleCheckTimer()
        observeSystemSleepWakeForSessionLifecycle()

        applySmokeTestEnvironmentHooksIfNeeded()
    }

    /// Applies environment-variable-driven hooks used by the CI smoke test
    /// in `claude-cursorUITests/OneShotAutomationSmokeTest.swift`. Read
    /// only when `CLAUDE_CURSOR_SMOKE_TEST_ENABLED=1` so production and
    /// everyday-dev launches are unaffected even if the other variables
    /// leak into the environment somehow.
    ///
    /// Two hooks:
    /// - `CLAUDE_CURSOR_FORCE_ONE_SHOT_AUTOMATION=1` flips
    ///   `preferOneShotAutomationForDebugging = true` so the demoted
    ///   one-shot CGEvent path gets exercised even though Computer Use is
    ///   now the default.
    /// - `CLAUDE_CURSOR_SMOKE_TEST_UTTERANCE` — if set, is dispatched as
    ///   if the user had typed it into the chat window, after a short
    ///   delay to give the overlay / screen-capture pipeline time to
    ///   settle. This lets the XCUITest drive the full transcript →
    ///   Claude → tool pipeline without synthesizing audio input.
    private func applySmokeTestEnvironmentHooksIfNeeded() {
        let environment = ProcessInfo.processInfo.environment
        guard environment["CLAUDE_CURSOR_SMOKE_TEST_ENABLED"] == "1" else { return }

        if environment["CLAUDE_CURSOR_FORCE_ONE_SHOT_AUTOMATION"] == "1" {
            setPreferOneShotAutomationForDebugging(true)
            print("🧪 Smoke test: forcing one-shot automation path")
        }

        if let smokeTestUtterance = environment["CLAUDE_CURSOR_SMOKE_TEST_UTTERANCE"],
           !smokeTestUtterance.isEmpty {
            print("🧪 Smoke test: scheduling utterance: \(smokeTestUtterance)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                self?.sendTextMessage(smokeTestUtterance)
            }
        }
    }

    /// Starts a repeating timer that checks once per minute whether the
    /// current session has been idle long enough to end and compress.
    private func startSessionIdleCheckTimer() {
        sessionIdleCheckTimer?.invalidate()
        sessionIdleCheckTimer = Timer.scheduledTimer(
            withTimeInterval: 60,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.endSessionIfIdleTimeoutReached()
            }
        }
    }

    /// If the current session has been idle for longer than
    /// `sessionIdleTimeoutSeconds`, end it and compress it into a wiki page.
    /// The next `recordObservedTurn` call will create a fresh session.
    private func endSessionIfIdleTimeoutReached() async {
        guard currentSessionObserverAgent != nil,
              let lastTimestamp = lastSessionInteractionTimestamp else { return }

        let secondsSinceLastInteraction = Date().timeIntervalSince(lastTimestamp)
        guard secondsSinceLastInteraction >= Self.sessionIdleTimeoutSeconds else { return }

        print("🔎 Session idle timeout reached (\(Int(secondsSinceLastInteraction))s) — ending session")
        await endCurrentSessionAndCompressForObserver()
        lastSessionInteractionTimestamp = nil
    }

    /// Ends the current session when the Mac goes to sleep so it gets
    /// compressed before a potentially long gap. On wake, the next
    /// interaction starts a fresh session automatically.
    private func observeSystemSleepWakeForSessionLifecycle() {
        let notificationCenter = NSWorkspace.shared.notificationCenter
        notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard self?.currentSessionObserverAgent != nil else { return }
                print("🔎 System sleeping — ending current session")
                await self?.endCurrentSessionAndCompressForObserver()
                self?.lastSessionInteractionTimestamp = nil
            }
        }
    }

    /// Attaches or detaches the Escape-key monitor. Called whenever the
    /// automation engine's running flag flips so the user only sees their
    /// Escape intercepted during an active sequence.
    private func updateAutomationEscapeKeyMonitor(enable shouldEnable: Bool) {
        if shouldEnable, automationEscapeKeyMonitor == nil {
            automationEscapeKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] keyDownEvent in
                // Keycode 53 is Escape on every US/INTL Mac keyboard.
                if keyDownEvent.keyCode == 53 {
                    self?.automationEngine.requestHaltOfCurrentSequence()
                    print("🛑 AutomationEngine: Escape pressed — halting sequence")
                    return nil
                }
                return keyDownEvent
            }
        } else if !shouldEnable, let existingMonitor = automationEscapeKeyMonitor {
            NSEvent.removeMonitor(existingMonitor)
            automationEscapeKeyMonitor = nil
        }
    }

    /// Called by BlueCursorView after the buddy finishes its pointing
    /// animation and returns to cursor-following mode.
    /// Triggers the onboarding sequence — dismisses the panel and restarts
    /// the overlay so the welcome animation and intro video play.
    func triggerOnboarding() {
        // Post notification so the panel manager can dismiss the panel
        NotificationCenter.default.post(name: .claudeCursorDismissPanel, object: nil)

        // Mark onboarding as completed so the Start button won't appear
        // again on future launches — the cursor will auto-show instead
        hasCompletedOnboarding = true

        ClaudeCursorAnalytics.trackOnboardingStarted()

        // Play Besaid theme at 60% volume, fade out after 1m 30s
        startOnboardingMusic()

        // Show the overlay for the first time — isFirstAppearance triggers
        // the welcome animation and onboarding video
        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
        isOverlayVisible = true
    }

    /// Replays the onboarding experience from the "Watch Onboarding Again"
    /// footer link. Same flow as triggerOnboarding but the cursor overlay
    /// is already visible so we just restart the welcome animation and video.
    func replayOnboarding() {
        NotificationCenter.default.post(name: .claudeCursorDismissPanel, object: nil)
        ClaudeCursorAnalytics.trackOnboardingReplayed()
        startOnboardingMusic()
        // Tear down any existing overlays and recreate with isFirstAppearance = true
        overlayWindowManager.hasShownOverlayBefore = false
        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
        isOverlayVisible = true
    }

    private func stopOnboardingMusic() {
        onboardingMusicFadeTimer?.invalidate()
        onboardingMusicFadeTimer = nil
        onboardingMusicPlayer?.stop()
        onboardingMusicPlayer = nil
    }

    private func startOnboardingMusic() {
        stopOnboardingMusic()
        guard let musicURL = Bundle.main.url(forResource: "ff", withExtension: "mp3") else {
            print("⚠️ ClaudeCursor: ff.mp3 not found in bundle")
            return
        }

        do {
            let player = try AVAudioPlayer(contentsOf: musicURL)
            player.volume = 0.3
            player.play()
            self.onboardingMusicPlayer = player

            // After 1m 30s, fade the music out over 3s
            onboardingMusicFadeTimer = Timer.scheduledTimer(withTimeInterval: 90.0, repeats: false) { [weak self] _ in
                self?.fadeOutOnboardingMusic()
            }
        } catch {
            print("⚠️ ClaudeCursor: Failed to play onboarding music: \(error)")
        }
    }

    private func fadeOutOnboardingMusic() {
        guard let player = onboardingMusicPlayer else { return }

        let fadeSteps = 30
        let fadeDuration: Double = 3.0
        let stepInterval = fadeDuration / Double(fadeSteps)
        let volumeDecrement = player.volume / Float(fadeSteps)
        var stepsRemaining = fadeSteps

        onboardingMusicFadeTimer = Timer.scheduledTimer(withTimeInterval: stepInterval, repeats: true) { [weak self] timer in
            stepsRemaining -= 1
            player.volume -= volumeDecrement

            if stepsRemaining <= 0 {
                timer.invalidate()
                player.stop()
                self?.onboardingMusicPlayer = nil
                self?.onboardingMusicFadeTimer = nil
            }
        }
    }

    func clearDetectedElementLocation() {
        activePointingTargets.removeAll()
    }

    // MARK: - Explainer Cursor Group Lifecycle

    func publishExplainerCursorGroup(_ group: ExplainerCursorGroup) {
        explainerAutoDismissTask?.cancel()
        explainerOverviewSpeechTask?.cancel()
        explainerOverviewSpeechTask = nil
        elevenLabsTTSClient.stopPlayback()
        isExplainerGroupReturning = false
        activeExplainerCursorGroup = group
        startExplainerOverviewSpeechIfNeeded(spokenOverview: group.spokenOverview)
        scheduleExplainerAutoDismiss(
            spokenOverviewTrimmed: group.spokenOverview.trimmingCharacters(in: .whitespacesAndNewlines),
            explainerPublishDate: group.createdAt
        )
    }

    /// Kicks off ElevenLabs for `spoken_overview` without blocking the tool-use loop. Sets `voiceState` to `.responding` once audio begins.
    private func startExplainerOverviewSpeechIfNeeded(spokenOverview: String) {
        let trimmedOverview = spokenOverview.trimmingCharacters(in: .whitespacesAndNewlines)
        explainerOverviewSpeechTask?.cancel()
        explainerOverviewSpeechTask = nil
        explainerOverviewRawForDedupThisTurn = nil

        guard !trimmedOverview.isEmpty else { return }

        explainerOverviewRawForDedupThisTurn = trimmedOverview
        explainerOverviewSpeechTask = Task { @MainActor [weak self] in
            guard let self else { return }
            if Task.isCancelled { return }
            do {
                try await self.elevenLabsTTSClient.speakText(trimmedOverview)
                if Task.isCancelled { return }
                self.voiceState = .responding
            } catch {
                if !Task.isCancelled {
                    print("⚠️ Explainer overview TTS failed: \(error)")
                }
            }
            if !Task.isCancelled {
                self.explainerOverviewSpeechTask = nil
            }
        }
    }

    func dismissExplainerCursorGroup(animated: Bool = true) {
        explainerAutoDismissTask?.cancel()
        explainerAutoDismissTask = nil

        guard activeExplainerCursorGroup != nil else { return }

        if animated {
            isExplainerGroupReturning = true
            // Allow 600ms for the return-to-main animation to play.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 600_000_000)
                activeExplainerCursorGroup = nil
                isExplainerGroupReturning = false
            }
        } else {
            activeExplainerCursorGroup = nil
            isExplainerGroupReturning = false
        }
    }

    /// Auto-dismiss after explainer-linked TTS finishes + a reading window. Keeps tips on screen at least a few seconds after publish so follow-up API iterations can still stream.
    private func scheduleExplainerAutoDismiss(
        spokenOverviewTrimmed: String,
        explainerPublishDate: Date
    ) {
        explainerAutoDismissTask?.cancel()
        explainerAutoDismissTask = Task { @MainActor [weak self] in
            guard let self else { return }

            if !spokenOverviewTrimmed.isEmpty {
                var pollCount = 0
                while !self.elevenLabsTTSClient.isPlaying && pollCount < 300 {
                    try? await Task.sleep(nanoseconds: 200_000_000)
                    if Task.isCancelled { return }
                    pollCount += 1
                }
                while self.elevenLabsTTSClient.isPlaying {
                    try? await Task.sleep(nanoseconds: 200_000_000)
                    if Task.isCancelled { return }
                }
            } else {
                var pollCount = 0
                while !self.elevenLabsTTSClient.isPlaying && pollCount < 150 {
                    try? await Task.sleep(nanoseconds: 200_000_000)
                    if Task.isCancelled { return }
                    pollCount += 1
                }
                if self.elevenLabsTTSClient.isPlaying {
                    while self.elevenLabsTTSClient.isPlaying {
                        try? await Task.sleep(nanoseconds: 200_000_000)
                        if Task.isCancelled { return }
                    }
                } else {
                    try? await Task.sleep(nanoseconds: 12_000_000_000)
                    if Task.isCancelled { return }
                }
            }

            let minimumSecondsVisibleFromPublish: TimeInterval = 8
            let elapsedSincePublish = Date().timeIntervalSince(explainerPublishDate)
            if elapsedSincePublish < minimumSecondsVisibleFromPublish {
                let remainingNanoseconds = UInt64(
                    (minimumSecondsVisibleFromPublish - elapsedSincePublish) * 1_000_000_000
                )
                try? await Task.sleep(nanoseconds: remainingNanoseconds)
                if Task.isCancelled { return }
            }

            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if Task.isCancelled { return }

            self.dismissExplainerCursorGroup(animated: true)
        }
    }

    /// Starts waiting for the next primary pointing flight to complete.
    /// Returns a wait ID the caller can pass to
    /// `waitForPrimaryPointingForwardArrival`.
    func beginAwaitingPrimaryPointingForwardArrival() -> Int {
        nextPrimaryPointingArrivalWaitID += 1
        let waitID = nextPrimaryPointingArrivalWaitID

        // Cancel any stale waiter before replacing it.
        primaryPointingArrivalContinuation?.resume(returning: false)
        primaryPointingArrivalContinuation = nil
        awaitingPrimaryPointingArrivalWaitID = waitID
        return waitID
    }

    /// Called by BlueCursorView when the buddy lands at the primary target.
    func signalPrimaryPointingForwardFlightArrived() {
        guard let awaitingWaitID = awaitingPrimaryPointingArrivalWaitID else { return }
        latestSignaledPrimaryPointingArrivalWaitID = awaitingWaitID
        awaitingPrimaryPointingArrivalWaitID = nil
        primaryPointingArrivalContinuation?.resume(returning: true)
        primaryPointingArrivalContinuation = nil
    }

    /// Waits for the primary pointing flight to finish or times out.
    func waitForPrimaryPointingForwardArrival(
        waitID: Int,
        timeoutNanoseconds: UInt64
    ) async -> Bool {
        if latestSignaledPrimaryPointingArrivalWaitID >= waitID {
            return true
        }

        return await withCheckedContinuation { continuation in
            guard awaitingPrimaryPointingArrivalWaitID == waitID else {
                continuation.resume(returning: false)
                return
            }

            primaryPointingArrivalContinuation = continuation

            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                guard let self else { return }
                guard self.awaitingPrimaryPointingArrivalWaitID == waitID else { return }
                self.awaitingPrimaryPointingArrivalWaitID = nil
                self.primaryPointingArrivalContinuation?.resume(returning: false)
                self.primaryPointingArrivalContinuation = nil
            }
        }
    }

    func stop() {
        globalPushToTalkShortcutMonitor.stop()
        buddyDictationManager.cancelCurrentDictation()
        overlayWindowManager.hideOverlay()
        transientHideTask?.cancel()
        stopTutorIdleObservation()

        currentResponseTask?.cancel()
        currentResponseTask = nil
        shortcutTransitionCancellable?.cancel()
        voiceStateCancellable?.cancel()
        audioPowerCancellable?.cancel()
        accessibilityCheckTimer?.invalidate()
        accessibilityCheckTimer = nil
        sessionIdleCheckTimer?.invalidate()
        sessionIdleCheckTimer = nil

        // Best-effort session close: if the user had an active session when
        // they quit, end it and fire the compressor. We don't block the
        // quit sequence — applicationWillTerminate gives us only a brief
        // window, so the compressor call is fire-and-forget. The raw
        // session log on disk is the authoritative record.
        if currentSessionObserverAgent != nil {
            Task { [weak self] in
                await self?.endCurrentSessionAndCompressForObserver()
            }
        }

        // Tear down the automation Escape monitor if one is still attached.
        // Leaves it pending would trap Escape in the next launch.
        automationRunningStateCancellable?.cancel()
        if let existingMonitor = automationEscapeKeyMonitor {
            NSEvent.removeMonitor(existingMonitor)
            automationEscapeKeyMonitor = nil
        }
    }

    // MARK: - Chat Window

    /// Controller for the floating chat transcript window. Created lazily
    /// on first use since the chat panel may never be opened.
    private(set) lazy var chatWindowController: ChatWindowController = {
        ChatWindowController(companionManager: self)
    }()

    // MARK: - Answer Panel

    /// Controller for the floating detailed-answer panel. Opened by the
    /// adaptive output router when Claude returns a long-form explanation.
    private(set) lazy var answerPanelController: AnswerPanelController = {
        AnswerPanelController(companionManager: self)
    }()

    // MARK: - Companion Mode State Machine

    /// High-level companion mode (idle/navigation/tutor/lesson/answer/chat).
    /// The state machine prevents conflicting modes from running simultaneously
    /// and drives routing decisions.
    let lessonStateMachine = LessonStateMachine()

    // MARK: - Proactive Tutor Prompt

    /// Controller for the proactive tutor speech bubble with y/n buttons.
    /// Shown during tutor mode before a proactive observation is spoken so
    /// the user can approve or dismiss before the companion takes over.
    private(set) lazy var proactiveTutorPromptController: ProactiveTutorPromptController = {
        ProactiveTutorPromptController()
    }()

    /// Blue-pill consent controller used for action-level approval (currently
    /// `start_automation_sequence`). Visually matches the NavigationBubbleView
    /// pill so the consent feels like it blooms out of the cursor rather than
    /// appearing as a separate dialog.
    private(set) lazy var cursorBubbleConsentPromptController: CursorBubbleConsentPromptController = {
        CursorBubbleConsentPromptController()
    }()

    // MARK: - Automation Engine (experimental)

    /// Experimental Phase F feature flag. Defaults off — automation is a
    /// no-op until the user explicitly turns it on in the menu bar. The
    /// flag is persisted in UserDefaults so the opt-in survives relaunches,
    /// but each sequence still requires a per-sequence consent prompt.
    @Published var isAutomationExperimentalEnabled: Bool = UserDefaults.standard.bool(
        forKey: "ClaudeCursor.isAutomationExperimentalEnabled"
    )

    /// Persists the experimental automation flag and updates the in-memory
    /// value. Called from the menu bar panel toggle.
    func setAutomationExperimentalEnabled(_ enabled: Bool) {
        isAutomationExperimentalEnabled = enabled
        UserDefaults.standard.set(
            enabled,
            forKey: "ClaudeCursor.isAutomationExperimentalEnabled"
        )
    }

    /// CGEvent-based automation dispatcher. Uses the blue-pill consent
    /// controller so consent visually matches the rest of the cursor-side
    /// chrome, and writes audit records to the wiki's raw/ directory for
    /// user inspection.
    private(set) lazy var automationEngine: AutomationEngine = {
        AutomationEngine(
            consentPromptController: cursorBubbleConsentPromptController,
            wikiManager: wikiManager
        )
    }()

    /// Debug-only override that forces the demoted one-shot CGEvent path for
    /// `start_automation_sequence` instead of the Claude Computer Use agent
    /// loop (the current default). Exposed via a hidden debug submenu in the
    /// menu-bar panel (Option-click reveal) so normal users never encounter
    /// it. Persisted to UserDefaults so the choice survives relaunches.
    ///
    /// Why this exists: if Anthropic's Computer Use beta has an outage or
    /// regression, flipping this on restores the old, locally-dispatched
    /// automation path without shipping a new build. The CI smoke test in
    /// `claude-cursorUITests/OneShotAutomationSmokeTest.swift` keeps the
    /// escape hatch exercised so it doesn't rot silently.
    @Published var preferOneShotAutomationForDebugging: Bool = UserDefaults.standard.bool(
        forKey: "ClaudeCursor.preferOneShotAutomationForDebugging"
    )

    func setPreferOneShotAutomationForDebugging(_ enabled: Bool) {
        preferOneShotAutomationForDebugging = enabled
        UserDefaults.standard.set(enabled, forKey: "ClaudeCursor.preferOneShotAutomationForDebugging")
    }

    /// Shown on the cursor overlay while the Computer Use agent loop is running (step N/M).
    @Published var computerUseAutomationStatusLine: String = ""

    /// Builds a fresh executor for each automation run so the target display and run id stay accurate.
    func makeComputerUseActionExecutor(
        targetNSScreen: NSScreen,
        runMetrics: ComputerUseRunMetrics,
        runIdentifier: String
    ) -> ComputerUseActionExecutor {
        ComputerUseActionExecutor(
            automationEngine: automationEngine,
            targetNSScreen: targetNSScreen,
            runMetrics: runMetrics,
            rawDirectoryURL: wikiManager.rawDirectoryURL,
            runIdentifier: runIdentifier
        )
    }

    // MARK: - Follow-Along Lesson Mode

    /// Controller for the full-screen lesson overlay (pink/red step banner
    /// and bottom thumbnail strip). Created lazily so app startup isn't
    /// slowed by building the SwiftUI hosting view when no lesson is active.
    private(set) lazy var lessonOverlayController: LessonOverlayController = {
        let controller = LessonOverlayController()
        controller.onStepIndexChanged = { [weak self] newStepIndex, shouldSeekVideo in
            self?.handleLessonStepAdvance(
                toStepIndex: newStepIndex,
                shouldSeekVideoToStepStart: shouldSeekVideo
            )
        }
        controller.onLessonDismissed = { [weak self] in
            self?.stopFollowAlongTutorial()
        }
        controller.onPillFrameDidChange = { [weak self] in
            guard let self,
                  let anchorRect = controller.currentPillPanelFrame else {
                return
            }
            self.videoPiPController.positionPiPPanelBelowRect(anchorRect: anchorRect)
        }
        return controller
    }()

    /// Controller for the bottom-right PiP panel that plays the YouTube
    /// video alongside the lesson overlay. Delegate callbacks feed current
    /// playback position and state changes back to this manager.
    private(set) lazy var videoPiPController: VideoPiPController = {
        let controller = VideoPiPController()
        controller.delegate = self
        return controller
    }()

    /// Stateless lesson extractor. Re-created per-lesson so each extraction
    /// uses the currently-selected Claude model for step structuring.
    private func makeYouTubeLessonExtractor() -> YouTubeLessonExtractor {
        return YouTubeLessonExtractor(
            workerBaseURL: Self.workerBaseURL,
            claudeAPIForStepStructuring: claudeAPI
        )
    }

    /// The lesson currently being walked through, if any. Nil when lesson
    /// mode is not active. Used by the menu bar panel to display "Lesson
    /// in progress" state and by analytics to track engagement.
    @Published private(set) var activeLesson: Lesson?

    /// Whether a lesson extraction is currently in flight. The Start
    /// button in the panel should show a loading state while this is true.
    @Published private(set) var isLessonLoading: Bool = false

    /// Error message from the most recent lesson load attempt, surfaced in
    /// the menu bar panel. Cleared on the next successful start or when
    /// the user edits the tutorial URL field.
    @Published var lessonLoadErrorMessage: String?

    /// Timestamp of the most recent lesson progress persist, used to
    /// throttle SQLite writes driven by the ~4Hz PiP time-update callback.
    private var lastLessonProgressPersistTime: Date?

    /// Minimum seconds between lesson-progress writes. 5s strikes a
    /// balance between resume fidelity and write volume — if the app
    /// crashes, the user loses at most 5 seconds of playback position.
    private static let lessonProgressPersistThrottleSeconds: TimeInterval = 5.0

    /// Latest PiP playback time (~4×/s while the lesson player is running).
    /// Used when saving step index so next/prev can update the tip without
    /// seeking the video — progress still reflects where the user actually is
    /// in the timeline.
    private var lastPiPReportedCurrentTimeSeconds: Double = 0

    // MARK: - Persistent Pattern Database

    /// SQLite-backed persistence for lesson progress, session metadata,
    /// tutor nudge rate limiting, and confidence scores. Opened lazily on
    /// first access; explicitly opened during `start()` so failures surface
    /// up front.
    let patternDatabase = PatternDatabase()

    /// Whether the pattern database opened successfully. When false we
    /// skip rate-limit lookups and fall back to conservative defaults.
    private(set) var isPatternDatabaseOpen: Bool = false

    // MARK: - Wiki Knowledge

    /// Markdown-based wiki storage for user-specific knowledge. Used to
    /// augment tutor observations and answer responses with prior learnings
    /// when the "Wiki Knowledge" toggle is enabled.
    let wikiManager = WikiManager()

    /// Research pipeline that ingests curated docs or Tavily web results
    /// into the wiki's raw/sources/ directory. Lazy because its worker URL
    /// and dependency on wikiManager make it a small cost to construct, and
    /// most sessions won't trigger a research call.
    private(set) lazy var autoResearchPipeline: AutoResearchPipeline = {
        return AutoResearchPipeline(
            wikiManager: wikiManager,
            workerBaseURL: Self.workerBaseURL
        )
    }()

    /// Retrieves topic-matched, character-budgeted context bundles from
    /// the wiki for inclusion in Claude prompts. Replaces the MVP keyword
    /// matcher that used to live directly on WikiManager.
    private(set) lazy var wikiQueryEngine: WikiQueryEngine = {
        return WikiQueryEngine(wikiManager: wikiManager)
    }()

    /// Tool registry Claude can call against during voice turns. Wraps
    /// every existing subsystem (wiki, pointing, answer panel, clipboard,
    /// YouTube lessons, automation) behind JSON-schema tool definitions
    /// so the model picks what to use per-question instead of the user
    /// pre-toggling hard-off switches.
    private(set) lazy var toolRegistry: CompanionToolRegistry = {
        return CompanionToolRegistry(companionManager: self)
    }()

    /// Compresses a finished session's turns into a durable wiki page.
    /// Shared between the observer agent and the cold-start recap generator.
    /// Uses its own ClaudeAPI instance (fixed on Sonnet) so compression is
    /// unaffected by the user's current model selection.
    private(set) lazy var sessionCompressor: SessionCompressor = {
        let claudeAPIForCompression = ClaudeAPI(
            proxyURL: "\(Self.workerBaseURL)/chat",
            model: "claude-sonnet-4-6"
        )
        return SessionCompressor(
            claudeAPIForCompression: claudeAPIForCompression,
            wikiManager: wikiManager
        )
    }()

    /// Compresses freshly-ingested research sources (written by
    /// `autoResearchPipeline` into `raw/sources/`) into a single queryable
    /// wiki page under `pages/`. Without this bridge, ingested material
    /// lives on disk but never surfaces in `query_wiki` results because
    /// `WikiQueryEngine` only walks `pages/` + `index.md`.
    private(set) lazy var researchSourceCompressor: ResearchSourceCompressor = {
        let claudeAPIForCompression = ClaudeAPI(
            proxyURL: "\(Self.workerBaseURL)/chat",
            model: "claude-sonnet-4-6"
        )
        return ResearchSourceCompressor(
            claudeAPIForCompression: claudeAPIForCompression,
            wikiManager: wikiManager
        )
    }()

    /// Merges duplicate or related wiki pages into consolidated pages
    /// after session compression creates a new page.
    private(set) lazy var wikiPageConsolidator: WikiPageConsolidator = {
        let claudeAPIForConsolidation = ClaudeAPI(
            proxyURL: "\(Self.workerBaseURL)/chat",
            model: "claude-sonnet-4-6"
        )
        return WikiPageConsolidator(
            claudeAPIForConsolidation: claudeAPIForConsolidation,
            wikiManager: wikiManager
        )
    }()

    /// Active observer for the current session. Nil between sessions. A new
    /// observer is created lazily on first observed turn and ended when the
    /// user has been idle long enough or the app quits.
    private var currentSessionObserverAgent: ObserverAgent?

    /// PatternDatabase session ID for the current session, matching the
    /// `ObserverAgent`'s session. Wired into the DB's session tracking
    /// API so interaction counts and outcomes are queryable.
    private var currentPatternDatabaseSessionID: String?

    /// Exposes the observer session id for ancillary features (e.g. Computer Use run logging).
    var activePatternDatabaseSessionIdentifier: String? { currentPatternDatabaseSessionID }

    /// Key used to persist the most recent session's end time in
    /// UserDefaults, for cold-start recap detection.
    private static let lastSessionEndedAtUserDefaultsKey = "ClaudeCursor.lastSessionEndedAtTimestamp"

    /// Key used to persist the most recent session's log filename so the
    /// cold-start recap can open it.
    private static let lastSessionLogFilenameUserDefaultsKey = "ClaudeCursor.lastSessionLogFilename"

    /// Gap between sessions (in seconds) that qualifies as a cold start.
    /// Below this threshold, the previous session continues. Above it, the
    /// observer ends the old session (if not already ended) and starts fresh.
    private static let coldStartSessionGapThresholdSeconds: TimeInterval = 4 * 3600

    // MARK: - Tutor Nudge Rate Limits (PRD P0-4)

    /// Maximum tutor nudges per rolling hour. Above this threshold tutor
    /// observations are suppressed until the oldest nudge ages out.
    private static let maximumTutorNudgesPerHour: Int = 5

    /// After this many consecutive rejected nudges the system backs off to
    /// at most one nudge per hour until an acceptance resets the streak.
    private static let consecutiveRejectionsTriggeringBackoff: Int = 2

    /// Under backoff mode, the allowance drops to this many nudges per hour.
    private static let backoffTutorNudgesPerHour: Int = 1

    // MARK: - Session Idle Timeout

    /// After this many seconds of no interaction, the current session is
    /// ended and compressed into a wiki page. A new session starts
    /// automatically on the next interaction. Without this, menu bar apps
    /// that run for days would never compress sessions (only app quit
    /// triggers compression otherwise).
    private static let sessionIdleTimeoutSeconds: TimeInterval = 30 * 60

    /// Timestamp of the most recent user interaction recorded by the
    /// session observer. Used by the idle-timeout timer to decide when
    /// a session has gone stale.
    private var lastSessionInteractionTimestamp: Date?

    /// Timer that checks once per minute whether the current session has
    /// been idle long enough to end and compress.
    private var sessionIdleCheckTimer: Timer?

    /// Sends a typed text message through the same pipeline as voice input.
    /// Captures a fresh screenshot (matching the PRD's "typed messages are
    /// sent identically to push-to-talk") and processes the response. The
    /// `didSubmitViaChat` flag is carried through so the adaptive output
    /// router can prefer the answer panel for typed questions.
    func sendTextMessage(_ message: String) {
        guard !message.isEmpty else { return }
        sendTranscriptToClaudeWithScreenshot(
            transcript: message,
            didSubmitViaChat: true
        )
    }

    func refreshAllPermissions() {
        let previouslyHadAccessibility = hasAccessibilityPermission
        let previouslyHadScreenRecording = hasScreenRecordingPermission
        let previouslyHadMicrophone = hasMicrophonePermission
        let previouslyHadAll = allPermissionsGranted

        let currentlyHasAccessibility = WindowPositionManager.hasAccessibilityPermission()
        hasAccessibilityPermission = currentlyHasAccessibility

        if currentlyHasAccessibility {
            globalPushToTalkShortcutMonitor.start()
        } else {
            globalPushToTalkShortcutMonitor.stop()
        }

        hasScreenRecordingPermission = WindowPositionManager.hasScreenRecordingPermission()

        let micAuthStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        hasMicrophonePermission = micAuthStatus == .authorized

        // Debug: log permission state on changes
        if previouslyHadAccessibility != hasAccessibilityPermission
            || previouslyHadScreenRecording != hasScreenRecordingPermission
            || previouslyHadMicrophone != hasMicrophonePermission {
            print("🔑 Permissions — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission)")
        }

        // Track individual permission grants as they happen
        if !previouslyHadAccessibility && hasAccessibilityPermission {
            ClaudeCursorAnalytics.trackPermissionGranted(permission: "accessibility")
        }
        if !previouslyHadScreenRecording && hasScreenRecordingPermission {
            ClaudeCursorAnalytics.trackPermissionGranted(permission: "screen_recording")
        }
        if !previouslyHadMicrophone && hasMicrophonePermission {
            ClaudeCursorAnalytics.trackPermissionGranted(permission: "microphone")
        }
        // Screen content permission is persisted — once the user has approved the
        // SCShareableContent picker, we don't need to re-check it.
        if !hasScreenContentPermission {
            hasScreenContentPermission = UserDefaults.standard.bool(forKey: "hasScreenContentPermission")
        }

        if !previouslyHadAll && allPermissionsGranted {
            ClaudeCursorAnalytics.trackAllPermissionsGranted()
        }
    }

    /// Triggers the macOS screen content picker by performing a dummy
    /// screenshot capture. Once the user approves, we persist the grant
    /// so they're never asked again during onboarding.
    @Published private(set) var isRequestingScreenContent = false

    func requestScreenContentPermission() {
        guard !isRequestingScreenContent else { return }
        isRequestingScreenContent = true
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first else {
                    await MainActor.run { isRequestingScreenContent = false }
                    return
                }
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let config = SCStreamConfiguration()
                config.width = 320
                config.height = 240
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                // Verify the capture actually returned real content — a 0x0 or
                // fully-empty image means the user denied the prompt.
                let didCapture = image.width > 0 && image.height > 0
                print("🔑 Screen content capture result — width: \(image.width), height: \(image.height), didCapture: \(didCapture)")
                await MainActor.run {
                    isRequestingScreenContent = false
                    guard didCapture else { return }
                    hasScreenContentPermission = true
                    UserDefaults.standard.set(true, forKey: "hasScreenContentPermission")
                    ClaudeCursorAnalytics.trackPermissionGranted(permission: "screen_content")

                    // If onboarding was already completed, show the cursor overlay now
                    if hasCompletedOnboarding && allPermissionsGranted && !isOverlayVisible && isClaudeCursorEnabled {
                        overlayWindowManager.hasShownOverlayBefore = true
                        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                        isOverlayVisible = true
                    }
                }
            } catch {
                print("⚠️ Screen content permission request failed: \(error)")
                await MainActor.run { isRequestingScreenContent = false }
            }
        }
    }

    // MARK: - Private

    /// Triggers the system microphone prompt if the user has never been asked.
    /// Once granted/denied the status sticks and polling picks it up.
    private func promptForMicrophoneIfNotDetermined() {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined else { return }
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            Task { @MainActor [weak self] in
                self?.hasMicrophonePermission = granted
            }
        }
    }

    /// Polls all permissions frequently so the UI updates live after the
    /// user grants them in System Settings. Screen Recording is the exception —
    /// macOS requires an app restart for that one to take effect.
    private func startPermissionPolling() {
        accessibilityCheckTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshAllPermissions()
            }
        }
    }

    private func bindAudioPowerLevel() {
        audioPowerCancellable = buddyDictationManager.$currentAudioPowerLevel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] powerLevel in
                self?.currentAudioPowerLevel = powerLevel
            }
    }

    private func bindVoiceStateObservation() {
        voiceStateCancellable = buddyDictationManager.$isRecordingFromKeyboardShortcut
            .combineLatest(
                buddyDictationManager.$isFinalizingTranscript,
                buddyDictationManager.$isPreparingToRecord
            )
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isRecording, isFinalizing, isPreparing in
                guard let self else { return }
                // Keep `.responding` while the AI pipeline owns the turn, but
                // always surface push-to-talk activity: if the user interrupts
                // TTS or streaming and holds ctrl+option, dictation must drive
                // `.listening` / `.processing` so the waveform appears.
                if self.voiceState == .responding,
                   !isRecording, !isFinalizing, !isPreparing {
                    return
                }

                if isFinalizing {
                    self.voiceState = .processing
                } else if isRecording {
                    self.voiceState = .listening
                } else if isPreparing {
                    self.voiceState = .processing
                } else {
                    self.voiceState = .idle
                    // If the user pressed and released the hotkey without
                    // saying anything, no response task runs — schedule the
                    // transient hide here so the overlay doesn't get stuck.
                    // Only do this when no response is in flight, otherwise
                    // the brief idle gap between recording and processing
                    // would prematurely hide the overlay.
                    if self.currentResponseTask == nil {
                        self.scheduleTransientHideIfNeeded()
                    }
                }
            }
    }

    private func bindShortcutTransitions() {
        shortcutTransitionCancellable = globalPushToTalkShortcutMonitor
            .shortcutTransitionPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] transition in
                self?.handleShortcutTransition(transition)
            }
    }

    private var answerPanelModeCancellable: AnyCancellable?

    /// Observes mode transitions so the answer panel hides when the companion
    /// enters a mode that owns the screen exclusively (currently `.lesson`).
    /// Without this, a lingering answer panel could overlap with the lesson
    /// step overlay and confuse the user.
    private func bindAnswerPanelModeObservation() {
        answerPanelModeCancellable = lessonStateMachine.$currentMode
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newMode in
                guard let self else { return }
                if newMode == .lesson && self.answerPanelController.isAnswerPanelVisible {
                    self.answerPanelController.hideAnswerPanel()
                }
            }
    }

    private func handleShortcutTransition(_ transition: BuddyPushToTalkShortcut.ShortcutTransition) {
        switch transition {
        case .pressed:
            guard !buddyDictationManager.isDictationInProgress else { return }
            // Don't register push-to-talk while the onboarding video is playing
            guard !showOnboardingVideo else { return }

            // Cancel any pending transient hide so the overlay stays visible
            transientHideTask?.cancel()
            transientHideTask = nil

            // If the cursor is hidden, bring it back transiently for this interaction
            if !isClaudeCursorEnabled && !isOverlayVisible {
                overlayWindowManager.hasShownOverlayBefore = true
                overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                isOverlayVisible = true
            }

            // Dismiss the menu bar panel so it doesn't cover the screen
            NotificationCenter.default.post(name: .claudeCursorDismissPanel, object: nil)

            // Cancel any in-progress response and TTS from a previous utterance
            currentResponseTask?.cancel()
            elevenLabsTTSClient.stopPlayback()
            clearDetectedElementLocation()
            dismissExplainerCursorGroup(animated: false)

            // Dismiss the onboarding prompt if it's showing
            if showOnboardingPrompt {
                withAnimation(.easeOut(duration: 0.3)) {
                    onboardingPromptOpacity = 0.0
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    self.showOnboardingPrompt = false
                    self.onboardingPromptText = ""
                }
            }
    

            ClaudeCursorAnalytics.trackPushToTalkStarted()

            pendingKeyboardShortcutStartTask?.cancel()
            pendingKeyboardShortcutStartTask = Task {
                await buddyDictationManager.startPushToTalkFromKeyboardShortcut(
                    currentDraftText: "",
                    updateDraftText: { _ in
                        // Partial transcripts are hidden (waveform-only UI)
                    },
                    submitDraftText: { [weak self] finalTranscript in
                        self?.lastTranscript = finalTranscript
                        print("🗣️ Companion received transcript: \(finalTranscript)")
                        ClaudeCursorAnalytics.trackUserMessageSent(transcript: finalTranscript)
                        self?.sendTranscriptToClaudeWithScreenshot(transcript: finalTranscript)
                    }
                )
            }
        case .released:
            // Cancel the pending start task in case the user released the shortcut
            // before the async startPushToTalk had a chance to begin recording.
            // Without this, a quick press-and-release drops the release event and
            // leaves the waveform overlay stuck on screen indefinitely.
            ClaudeCursorAnalytics.trackPushToTalkReleased()
            pendingKeyboardShortcutStartTask?.cancel()
            pendingKeyboardShortcutStartTask = nil
            buddyDictationManager.stopPushToTalkFromKeyboardShortcut()
        case .none:
            break
        }
    }

    // MARK: - Companion Prompt

    /// Tool-aware voice prompt used by `analyzeImageStreamingWithTools`
    /// on the main voice path and all other agentic paths (tutor
    /// observation, post-navigation polling, onboarding demo). Teaches
    /// Claude to call tools (`point_at_element`, `query_wiki`,
    /// `open_answer_panel`, `copy_response_to_clipboard`,
    /// `start_youtube_lesson`, `start_automation_sequence`) instead of
    /// emitting inline coordination tags like `[POINT:...]`. The legacy
    /// tag-based prompt was removed after every path migrated.
    private static let companionVoiceResponseSystemPromptWithTools = """
    you're claude cursor, a friendly always-on companion that lives in the user's menu bar. the user just spoke to you via push-to-talk and you can see their screen(s). your reply will be spoken aloud via text-to-speech, so write the way you'd actually talk. this is an ongoing conversation — you remember everything they've said before.

    rules:
    - default to one or two sentences. be direct and dense. BUT if the user asks you to explain more, go deeper, or elaborate, then go all out — give a thorough, detailed explanation with no length limit.
    - all lowercase, casual, warm. no emojis.
    - write for the ear, not the eye. short sentences. no lists, bullet points, markdown, or formatting in your spoken reply — just natural speech. (markdown is fine inside the `open_answer_panel` tool's content.)
    - don't use abbreviations or symbols that sound weird read aloud. write "for example" not "e.g.", spell out small numbers.
    - if the user's question relates to what's on their screen, reference specific things you see.
    - if the screenshot doesn't seem relevant to their question, just answer the question directly.
    - never say "simply" or "just".
    - don't read out code verbatim. if they want code, call open_answer_panel with a fenced block instead.
    - focus on giving a thorough, useful explanation. don't end with simple yes/no questions like "want me to explain more?" — end by planting a seed about something deeper worth exploring, or stop cleanly if the answer's complete.
    - if you receive multiple screen images, the one labeled "primary focus" is where the cursor is — prioritize that one but reference others if relevant.

    you have tools for taking real actions. USE THEM liberally when they fit:

    - point_at_element: whenever your answer references a specific UI element by name ("click export", "go to the deliver page"), call point_at_element on the matching element. call it MULTIPLE TIMES in one response if your answer references multiple elements — the user can see all the pointers at once. coordinates are in screenshot pixel space; screen_number is 1-indexed.
    - explain_screen_elements: when the user asks "how does this app work?", "walk me through this interface", "what am I looking at?", or any question where multiple UI elements need simultaneous explanation. deploys colored sub-cursors that fan out from the main cursor to different elements, each with a label and one-sentence description. use this instead of multiple point_at_element calls when the intent is an overview, not step-by-step navigation. max 8 elements, ordered by priority (critical first). you MUST fill `spoken_overview` with 1-3 spoken sentences — that audio plays the instant the cursors appear. your final assistant text after the tool should be empty or at most a very short non-repeating closing (do not paraphrase `spoken_overview` again); the labels teach the details.
    - query_wiki: when the question touches something the user might have asked about before (software workflows, tools, personal conventions), call query_wiki FIRST with 2-3 keywords, then ground your spoken answer in the bundle you get back.
    - research_topic: when the user explicitly says "research X" / "look up X" / "learn about X in <app>", OR when query_wiki came back empty and the question genuinely needs background docs, call research_topic({topic: "..."}) once. it fetches curated docs + falls back to web search and writes them to the user's wiki. takes 15-30s. the ingest runs in the background, so DO NOT try to cite specifics from it in your current reply — just acknowledge it ("i pulled in new docs on X — next time you ask, i'll cite them"). do NOT chain research_topic → query_wiki in the same turn; the page won't be indexed yet. call at most once per turn.
    - open_answer_panel: for math (use LaTeX $$...$$), code (use fenced blocks), or multi-paragraph explanations, call open_answer_panel with the full markdown content. your spoken reply should then be one short sentence like "the breakdown is in the panel."
    - copy_response_to_clipboard: only if the user says "copy this" or "paste it into X". never auto-copy.
    - start_youtube_lesson: ONLY when the user explicitly gives you a YouTube URL and asks to be walked through it. never suggest or start a YouTube lesson unless the user provides a URL.
    - start_automation_sequence: only when the user explicitly asks you to do something for them ("take me to the export settings", "do this for me"). the user will see a consent prompt before anything happens.

    concrete examples of picking the right tool based on what the user wants:
    - "how does this app work?" or "walk me through this" or "explain this screen" → explain_screen_elements with the most important UI regions plus a `spoken_overview` that matches what you'd say aloud; keep closing assistant text minimal so it isn't repeated on tts.
    - "give me a tutorial on resolve" or "teach me how to use X" → call query_wiki first with the app name, then use point_at_element to walk them through step by step. if the question is broad ("how does this whole thing work?"), use explain_screen_elements for an overview first.
    - "where is the export button?" or "click settings" → point_at_element (specific element, not an overview).
    - "how do i open X in Y app" or "where's the Z button" → call query_wiki first with the app name + feature, then point_at_element at the matching UI element on screen. call point_at_element multiple times if your answer references multiple elements.
    - "take me to the export settings" or "click through to X for me" or "do this for me" → start_automation_sequence. the user sees a consent pill before anything runs.
    - math problems (integrals, derivatives, equations) or "solve this" → open_answer_panel with LaTeX $$...$$, then speak one short sentence like "the steps are in the panel."
    - code requests ("write me a function", "show me the syntax") → open_answer_panel with a fenced code block, then speak a one-liner pointing to the panel.
    - "copy that" / "paste this into X" → copy_response_to_clipboard with the exact text.
    - questions about the user's own past workflows, apps, or conventions → query_wiki FIRST, then answer grounded in the bundle.
    - "research X" / "look up X" / "learn about X in <app>" → research_topic({topic: "..."}). acknowledge the ingest; do NOT call query_wiki in the same turn.

    don't mix explain_screen_elements and point_at_element in the same turn — use one or the other.

    you can chain tools in one turn — e.g. query_wiki → point_at_element → speak. after action tools (point_at_element, start_automation_sequence) you get a fresh screenshot back as the tool result so you can verify the action landed and iterate if it didn't.

    do NOT emit `[POINT:...]` or `[STEP:...]` tags in your text — use the tools instead. your spoken text is read aloud verbatim, so a raw tag would be read as "bracket point colon" which is awful.

    for conversational replies that don't need tools, just speak naturally — your text is played through tts.
    """

    /// System prompt used when the user asks a math problem. Overrides the
    /// voice-response prompt's "don't use symbols that sound weird read
    /// aloud" rule because the answer panel's MathJax renderer typesets
    /// equations visually — so we want raw LaTeX, not spelled-out prose.
    ///
    /// Paired with `AdaptiveOutputRouter.containsMathOrLatexMarkup` which
    /// detects the `$$…$$` blocks this prompt produces and routes the
    /// response to the Answer panel.
    private static let companionMathResponseSystemPrompt = """
    you're claude cursor. the user just asked you to solve a math problem or work through an equation. render the answer as step-by-step typeset LaTeX so it can be read in the answer panel.

    format rules:
    - open with one short sentence restating what you're solving (plain text, no math symbols inline — e.g. "let's solve for x.").
    - then produce numbered steps. each step is a short plain-english sentence followed by the equation on its own line wrapped in $$...$$ (display math).
    - use standard latex: ^ for exponents, \\frac{a}{b} for fractions, \\sqrt{} for roots, \\pm for plus-or-minus, \\int, \\sum, \\lim, \\cdot, etc.
    - end with one short plain-english sentence stating the final answer, and include the answer in $$...$$ on its own line.
    - do NOT use inline $...$ math. always use $$...$$ on its own line so the answer panel renders it as display math.
    - no lists, no headings, no bullet points. just sentences + $$ blocks.

    example for "solve 3x^2 + 2 = 5":

    let's solve for x.

    step 1: subtract 2 from both sides.
    $$3x^2 + 2 - 2 = 5 - 2$$
    $$3x^2 = 3$$

    step 2: divide both sides by 3.
    $$x^2 = 1$$

    step 3: take the square root of both sides.
    $$x = \\pm\\sqrt{1}$$
    $$x = \\pm 1$$

    so x equals positive or negative one.

    rendering: CALL `open_answer_panel` with the full LaTeX content as the tool input so it renders in the docked answer panel with MathJax typeset. your spoken reply should be one short sentence like "the steps are in the panel" — don't read the LaTeX aloud, that sounds awful.

    pointing: math answers don't point at anything on screen. do NOT emit `[POINT:...]` tags — leave pointing entirely to the `point_at_element` tool if it's ever needed, which it usually isn't for math.
    """

    private static let tutorModeSystemPrompt = """
    you're claude cursor in tutor mode. the user wants to LEARN whatever software they're currently using. you are their hands-on instructor who can see their screen.

    your primary approach is NAVIGATION-FIRST teaching:
    - proactively guide them step by step. don't wait to be asked.
    - if they just opened an app or screen and seem unsure where to start, use `explain_screen_elements` with a filled-in `spoken_overview` so narration starts with the visual map — deploy colored sub-cursors to the most important UI regions so they can orient themselves. once they've oriented, switch to `point_at_element` for step-by-step guidance.
    - for specific next-step guidance ("now click this, then that"), use `point_at_element` — a tutor who can point is way more useful than one who just talks.
    - after they complete a step, acknowledge it and tell them the next one.
    - if they go off track, gently redirect.
    - teach concepts as they become relevant, not all at once.
    - if they're doing well, say so and push them to the next level.
    - if the screen hasn't changed since your last observation, say something encouraging or suggest what to click next — don't repeat yourself.
    - ask the user questions to check understanding — "do you see the timeline at the bottom?" or "what do you think that icon does?" makes learning interactive.

    keep a warm, friendly voice. short sentences. all lowercase, casual. you're a helpful friend walking them through it, not a corporate trainer.

    important: check conversation history to avoid repeating what you already said. each observation should build on the last, not restart from scratch.

    tool usage for tutor mode:
    - prefer `point_at_element` for concrete "click this next" guidance. call it multiple times in one turn to light up multiple steps (e.g. "first click File, then Export").
    - use `explain_screen_elements` when the user needs an overview of a whole screen or panel — not for single-element directions. always include `spoken_overview` (heard together with the cursors); don't repeat that prose in your final message after the tool.
    - don't mix `explain_screen_elements` and `point_at_element` in the same turn — use one or the other.
    - use `query_wiki` for app-specific context when it helps ground your guidance.
    - you MAY call `start_automation_sequence` when you want to offer to perform a navigation step for the user. phrase it as a suggestion in your spoken text ("want me to take you there?") — the user will see a consent prompt with y/n buttons before anything executes.
    - do NOT call `start_youtube_lesson` during tutor nudges. tutor mode teaches by pointing and navigating, not by pulling up videos.
    - avoid `open_answer_panel` for normal nudges; keep guidance spoken and hands-on.

    the screenshot images are labeled with their pixel dimensions. use those dimensions as the coordinate space. origin (0,0) is top-left. x increases rightward, y increases downward. pass `screen_number` from the screenshot label when pointing at a non-primary screen.

    end your turn with the spoken guidance as your final text — no `[POINT:...]` tags, no extra formatting.
    """

    // MARK: - AI Response Pipeline

    /// Captures a screenshot, sends it along with the transcript to Claude,
    /// and plays the response aloud via ElevenLabs TTS. The cursor stays in
    /// the spinner/processing state until TTS audio begins playing.
    /// Claude may call `point_at_element` during the turn (via native
    /// tool-use) which makes the buddy fly to that element on screen.
    ///
    /// - Parameter transcript: The user's question, either a finalized voice
    ///   transcript or a typed chat message.
    /// - Parameter didSubmitViaChat: True when the user typed this message in
    ///   the chat window (vs push-to-talk). Carried into the adaptive output
    ///   router so typed questions prefer the panel surface.
    private func sendTranscriptToClaudeWithScreenshot(
        transcript: String,
        didSubmitViaChat: Bool = false
    ) {
        currentResponseTask?.cancel()
        explainerOverviewSpeechTask?.cancel()
        explainerOverviewSpeechTask = nil
        explainerOverviewRawForDedupThisTurn = nil
        elevenLabsTTSClient.stopPlayback()
        lessonStepPointingTask?.cancel()
        dismissExplainerCursorGroup(animated: false)

        // A new interaction supersedes any in-flight post-action polling —
        // the user just spoke / typed, so whatever the previous turn was
        // watching for no longer matters.
        stopPendingNavigationObservation()

        // Dismiss any stale answer panel from the previous interaction. If
        // the router picks .answer again this turn, the panel will reopen
        // with fresh content. This prevents old explanations from lingering
        // while the user asks something new.
        if answerPanelController.isAnswerPanelVisible {
            answerPanelController.hideAnswerPanel()
        }

        currentResponseTask = Task {
            // Stay in processing (spinner) state — no streaming text displayed
            voiceState = .processing

            // If the session compressor produced a warm recap for this cold
            // start, play it once before processing so the user hears it
            // while Claude is working on the fresh request. Clearing the
            // recap text here guarantees it only plays once per launch.
            if let recapToSpeak = pendingColdStartRecapText {
                pendingColdStartRecapText = nil
                Task { [weak self] in
                    guard let self else { return }
                    do {
                        try await self.elevenLabsTTSClient.speakText(recapToSpeak)
                    } catch {
                        print("⚠️ ColdStartRecap TTS failed: \(error)")
                    }
                }
            }

            do {
                // Capture all connected screens so the AI has full context
                let screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()

                guard !Task.isCancelled else { return }

                // Build image labels with the actual screenshot pixel dimensions
                // so Claude's coordinate space matches the image it sees. We
                // scale from screenshot pixels to display points ourselves.
                let labeledImages = screenCaptures.map { capture in
                    let dimensionInfo = " (image dimensions: \(capture.screenshotWidthInPixels)x\(capture.screenshotHeightInPixels) pixels)"
                    return (data: capture.imageData, label: capture.label + dimensionInfo)
                }

                // Pass conversation history so Claude remembers prior exchanges
                let historyForAPI = conversationHistory.map { entry in
                    (userPlaceholder: entry.userTranscript, assistantResponse: entry.assistantResponse)
                }

                // Augment the base voice system prompt with wiki context when
                // the user has Wiki Knowledge enabled. The user's transcript
                // is the strongest keyword source for voice interactions.
                //
                // Math questions swap in a dedicated prompt that produces
                // step-by-step `$$…$$` LaTeX blocks (the voice prompt
                // explicitly bans symbols that sound weird read aloud and
                // would otherwise produce prose like "three x squared").
                // Tool-aware path uses the tool-teaching prompt variant.
                // Math intent keeps its own LaTeX prompt (the math prompt
                // now also instructs calling `open_answer_panel`).
                let baseSystemPromptForTurn = containsMathIntent(inUserQuestion: transcript)
                    ? Self.companionMathResponseSystemPrompt
                    : Self.companionVoiceResponseSystemPromptWithTools
                let voiceSystemPromptWithWikiContext = systemPromptAugmentedWithWikiContext(
                    baseSystemPrompt: baseSystemPromptForTurn,
                    additionalKeywords: keywordsFromText(transcript)
                )

                // Prime the tool registry so `point_at_element` can resolve
                // screenshot coordinates, and `copy_response_to_clipboard`
                // knows what "the current response" means.
                toolRegistry.beginTurn(withScreenCaptures: screenCaptures)
                answerPanelController.resetMarkdownTrackingForNewTurn()
                defer { toolRegistry.endTurn() }

                let toolsAvailableThisTurn = toolRegistry.availableToolsForCurrentTurn()

                let (fullResponseText, _) = try await claudeAPI.analyzeImageStreamingWithTools(
                    images: labeledImages,
                    systemPrompt: voiceSystemPromptWithWikiContext,
                    conversationHistory: historyForAPI,
                    userPrompt: transcript,
                    availableTools: toolsAvailableThisTurn,
                    executeToolCall: { [weak self] toolUseBlock in
                        guard let self else {
                            return ClaudeToolResultBlock(
                                toolUseID: toolUseBlock.id,
                                content: "companion unavailable",
                                isError: true
                            )
                        }
                        return await self.toolRegistry.executeToolCall(toolUseBlock)
                    },
                    onTextChunk: { [weak self] accumulatedTextSoFar in
                        Task { @MainActor [weak self] in
                            guard let self else { return }
                            self.toolRegistry.accumulatedResponseTextSoFar = accumulatedTextSoFar
                        }
                    }
                )

                guard !Task.isCancelled else { return }

                // Pointing targets were already published live by the
                // `point_at_element` tool executor — it writes straight to
                // `activePointingTargets`, flies the cursor, and records
                // analytics as each tool call lands. Here we just snapshot
                // whether any pointing happened this turn so the adaptive
                // output router can classify the response as `.navigation`.
                let hasPointCoordinate = toolRegistry.didPointingToolFireInCurrentTurn
                let spokenText = fullResponseText

                print("🎯 Element pointing this turn: \(hasPointCoordinate ? "yes" : "no")")

                // ── Adaptive output routing ────────────────────────────────
                // Decide which surface renders this response. Pointing
                // gestures stay on the cursor overlay labels; math/code open
                // the answer panel; everything else is spoken directly.
                let routerDecisionInput = AdaptiveOutputRouterInput(
                    fullResponseText: fullResponseText,
                    didResponseIncludePointTag: hasPointCoordinate,
                    isCurrentlyInLessonMode: lessonStateMachine.currentMode == .lesson,
                    didUserSubmitViaChatInput: didSubmitViaChat
                )
                let chosenOutputSurface = AdaptiveOutputRouter
                    .decideOutputSurface(for: routerDecisionInput)
                print("🎯 Router chose output surface: \(chosenOutputSurface)")

                // Route the response to the chosen output surface. Math /
                // code goes to the Answer panel; navigation plays through
                // the cursor pointing pipeline (OverlayWindow owns the
                // label pill). Chat / fallback stays voice-only.
                if chosenOutputSurface == .answer {
                    answerPanelController.showAnswerPanel(withResponseText: spokenText)
                    lessonStateMachine.requestTransition(to: .answer)
                } else if chosenOutputSurface == .navigation {
                    lessonStateMachine.requestTransition(to: .navigation)
                }

                // Prefer the last markdown shown in the answer panel this turn
                // (e.g. `open_answer_panel` payload) so chat history and
                // clipboard match what the user sees when the panel auto-opens.
                let assistantTextForUserFacingArtifacts = (
                    answerPanelController.markdownLastPresentedThisTurn ?? spokenText
                ).trimmingCharacters(in: .whitespacesAndNewlines)

                // Copy the response to the clipboard if the user has enabled
                // auto-copy. ClipboardManager defensively strips any residual
                // coordination tags so the pasted text is always user-ready.
                if isAutoCopyResponseEnabled {
                    ClipboardManager.copyResponseToClipboard(
                        rawResponseText: assistantTextForUserFacingArtifacts
                    )
                }

                // Save this exchange to conversation history so future
                // turns have full context.
                conversationHistory.append((
                    userTranscript: transcript,
                    assistantResponse: assistantTextForUserFacingArtifacts
                ))

                // Keep only the last 10 exchanges to avoid unbounded context growth
                if conversationHistory.count > 10 {
                    conversationHistory.removeFirst(conversationHistory.count - 10)
                }

                print("🧠 Conversation history: \(conversationHistory.count) exchanges")

                ClaudeCursorAnalytics.trackAIResponseReceived(
                    response: assistantTextForUserFacingArtifacts
                )

                // Record this turn in the session observer — captured after
                // routing so the log reflects which surface rendered the
                // response. PII stripping happens inside the observer.
                recordObservedTurn(
                    userTranscript: transcript,
                    assistantResponse: assistantTextForUserFacingArtifacts,
                    outputModeUsed: "\(chosenOutputSurface)"
                )

                // Proactive mode: after a navigation response with a
                // pointing coordinate, watch the screen so we can speak
                // the next step as soon as the user acts, instead of
                // waiting for another push-to-talk.
                if chosenOutputSurface == .navigation, hasPointCoordinate {
                    startPendingNavigationObservation(
                        afterUserTranscript: transcript,
                        afterAssistantResponse: assistantTextForUserFacingArtifacts
                    )
                }

                // Pick the TTS text: for answer-panel routing, speak a brief
                // confirmation so the user isn't listening to a 30-second
                // monologue they can read in 5 seconds. For every other
                // surface, speak the full cleaned response.
                let textForTTSPlayback = brieflySpokenTextForRoutingDecision(
                    chosenOutputSurface: chosenOutputSurface,
                    fullSpokenText: spokenText
                )
                let textForFinalSpeak: String
                if let explainerOverviewRaw = explainerOverviewRawForDedupThisTurn,
                   !explainerOverviewRaw.isEmpty {
                    textForFinalSpeak = ExplainerSpokenTextDedup.remainingAssistantTextAfterOverviewIfRedundant(
                        fullAssistantText: textForTTSPlayback,
                        explainerOverview: explainerOverviewRaw
                    )
                } else {
                    textForFinalSpeak = textForTTSPlayback
                }

                if let explainerOverviewRaw = explainerOverviewRawForDedupThisTurn,
                   !explainerOverviewRaw.isEmpty,
                   !textForFinalSpeak.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    await waitUntilElevenLabsPlaybackFinishesOrCancelled()
                }

                // Play the response via TTS. Keep the spinner (processing state)
                // until the audio actually starts playing, then switch to responding.
                if !textForFinalSpeak.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    do {
                        try await elevenLabsTTSClient.speakText(textForFinalSpeak)
                        // speakText returns after player.play() — audio is now playing
                        voiceState = .responding
                    } catch {
                        ClaudeCursorAnalytics.trackTTSError(error: error.localizedDescription)
                        print("⚠️ ElevenLabs TTS error: \(error)")
                        speakCreditsErrorFallback()
                    }
                }
            } catch is CancellationError {
                // User spoke again — response was interrupted
            } catch {
                ClaudeCursorAnalytics.trackResponseError(error: error.localizedDescription)
                print("⚠️ Companion response error: \(error)")
                speakCreditsErrorFallback()
            }

            if !Task.isCancelled {
                await waitUntilElevenLabsPlaybackFinishesOrCancelled()
            }
            if !Task.isCancelled {
                voiceState = .idle
                scheduleTransientHideIfNeeded()
            }
        }
    }

    /// Waits until ElevenLabs playback completes or the task is cancelled.
    private func waitUntilElevenLabsPlaybackFinishesOrCancelled() async {
        while elevenLabsTTSClient.isPlaying {
            try? await Task.sleep(nanoseconds: 200_000_000)
            if Task.isCancelled { return }
        }
    }

    /// When the adaptive output router picks the answer panel, we play a
    /// brief spoken confirmation rather than reading the entire response —
    /// the user can read the panel at their own pace. For every other
    /// surface, TTS plays the full cleaned response.
    ///
    /// - Parameter chosenOutputSurface: The surface the router selected.
    /// - Parameter fullSpokenText: The response text Claude streamed —
    ///   tool-use keeps coordinate payloads off the text stream, so no
    ///   tag stripping is needed before TTS.
    /// - Returns: The text that should be sent to the TTS engine.
    private func brieflySpokenTextForRoutingDecision(
        chosenOutputSurface: CompanionOutputSurface,
        fullSpokenText: String
    ) -> String {
        switch chosenOutputSurface {
        case .answer:
            // Short confirmation so the user knows where to look. Intentionally
            // brief — the full explanation is already visible in the panel.
            return "The breakdown is in the panel for you."
        case .navigation, .lesson, .chat:
            return fullSpokenText
        }
    }

    /// If the cursor is in transient mode (user toggled "Show ClaudeCursor" off),
    /// waits for TTS playback and any pointing animation to finish, then
    /// fades out the overlay after a 1-second pause. Cancelled automatically
    /// if the user starts another push-to-talk interaction.
    private func scheduleTransientHideIfNeeded() {
        guard !isClaudeCursorEnabled && isOverlayVisible else { return }

        transientHideTask?.cancel()
        transientHideTask = Task {
            // Wait for TTS audio to finish playing
            while elevenLabsTTSClient.isPlaying {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }

            // Wait for pointing animation to finish (location is cleared
            // when the buddy flies back to the cursor)
            while detectedElementScreenLocation != nil {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }

            // Pause 1s after everything finishes, then fade out
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            overlayWindowManager.fadeOutAndHideOverlay()
            isOverlayVisible = false
        }
    }

    // MARK: - Follow-Along Lesson Lifecycle

    /// Starts a follow-along YouTube tutorial. Extracts the lesson from the
    /// URL, resumes saved progress if this video has been watched before,
    /// and shows the lesson overlay + PiP panel. If extraction fails, sets
    /// `lessonLoadErrorMessage` so the menu bar panel can surface the
    /// problem without a blocking alert.
    ///
    /// Called from the menu bar panel's "Start" button on the follow-along
    /// tutorial row.
    func startFollowAlongTutorial() {
        let trimmedTutorialURL = followAlongTutorialURL.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !trimmedTutorialURL.isEmpty else { return }
        guard let parsedTutorialURL = URL(string: trimmedTutorialURL) else {
            lessonLoadErrorMessage = "That doesn't look like a valid URL."
            return
        }

        // Block concurrent extractions so rapid taps on Start don't spawn
        // duplicate work.
        guard !isLessonLoading else { return }

        // Request transition up front so a conflicting mode (e.g. a lesson
        // already running) can veto before we fetch a transcript.
        let transitionAccepted = lessonStateMachine.requestTransition(to: .lesson)
        guard transitionAccepted else {
            lessonLoadErrorMessage = "Can't start a lesson from the current mode. Stop the active mode first."
            return
        }

        isLessonLoading = true
        lessonLoadErrorMessage = nil

        // Hide other surfaces that would overlap the lesson overlay.
        if answerPanelController.isAnswerPanelVisible {
            answerPanelController.hideAnswerPanel()
        }
        proactiveTutorPromptController.dismissPrompt()

        let extractorForThisLesson = makeYouTubeLessonExtractor()

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isLessonLoading = false }

            do {
                let extractedLesson = try await extractorForThisLesson.extractLesson(
                    fromYouTubeURL: parsedTutorialURL
                )
                self.activateExtractedLesson(extractedLesson: extractedLesson)
            } catch let extractionError {
                print("❌ startFollowAlongTutorial: extraction failed — \(extractionError)")
                let friendlyErrorMessage = (extractionError as? LocalizedError)?.errorDescription
                    ?? "Couldn't load the tutorial. Try a different URL."
                self.lessonLoadErrorMessage = friendlyErrorMessage

                // Revert the state machine since we never actually started.
                self.lessonStateMachine.requestTransition(to: .idle)
            }
        }
    }

    /// Stops the active follow-along tutorial. Hides the overlay + PiP
    /// panel and returns the companion to idle mode. Safe to call when no
    /// lesson is active — no-ops in that case.
    func stopFollowAlongTutorial() {
        lessonStepPointingTask?.cancel()
        lessonOverlayController.hideLessonOverlay()
        videoPiPController.hidePiPPanel()
        activeLesson = nil
        // Only transition to idle if we're still in lesson mode — a new
        // mode may have already taken over via a parallel path.
        if lessonStateMachine.currentMode == .lesson {
            lessonStateMachine.requestTransition(to: .idle)
        }
    }

    /// Called once the lesson has been extracted. Resumes saved progress
    /// (if any), shows the step pill at the correct step, loads the PiP
    /// video seeked to that step's start timestamp, and anchors the PiP
    /// directly below the step pill.
    private func activateExtractedLesson(extractedLesson: Lesson) {
        activeLesson = extractedLesson

        let resumeStepIndex = resumeStepIndexForExtractedLesson(
            extractedLesson: extractedLesson
        )
        let resumeStartTimestampSeconds = extractedLesson.steps
            .indices.contains(resumeStepIndex)
            ? extractedLesson.steps[resumeStepIndex].startTimestampSeconds
            : 0

        lessonOverlayController.showLessonOverlay(
            forLesson: extractedLesson,
            startingAtStepIndex: resumeStepIndex
        )
        videoPiPController.showAndLoadVideo(
            youtubeVideoID: extractedLesson.youtubeVideoID,
            startAtTimeSeconds: resumeStartTimestampSeconds
        )

        // Anchor the PiP video directly below the step pill so they read
        // as a single visual unit. Falls back to the default bottom-right
        // if the pill frame isn't available yet (shouldn't happen in
        // practice since showLessonOverlay orders the panel front first).
        if let stepPillFrame = lessonOverlayController.currentPillPanelFrame {
            videoPiPController.positionPiPPanelBelowRect(
                anchorRect: stepPillFrame
            )
        }

        lastPiPReportedCurrentTimeSeconds = resumeStartTimestampSeconds

        persistLessonProgress(
            forLesson: extractedLesson,
            atStepIndex: resumeStepIndex,
            lastTimestampSeconds: resumeStartTimestampSeconds
        )

        pointCursorAtRelevantElementForLessonStep(atIndex: resumeStepIndex)
    }

    /// Looks up saved progress for this video and returns the step index
    /// to resume at. If progress exists but the lesson was already
    /// completed, restarts from step 0 — the user likely wants to rewatch.
    /// If no progress exists, returns 0.
    private func resumeStepIndexForExtractedLesson(
        extractedLesson: Lesson
    ) -> Int {
        guard isPatternDatabaseOpen else { return 0 }
        guard let savedProgress = patternDatabase.getLessonProgress(
            youtubeVideoID: extractedLesson.youtubeVideoID
        ) else {
            return 0
        }

        // Lesson was previously completed — start fresh on replay so the
        // overlay doesn't open at the very last step.
        if savedProgress.isCompleted {
            return 0
        }

        // Clamp in case the lesson was re-extracted with fewer steps than
        // the saved progress assumed.
        return max(
            0,
            min(savedProgress.currentStepIndex, extractedLesson.steps.count - 1)
        )
    }

    /// Invoked by `LessonOverlayController.onStepIndexChanged` when the
    /// step index changes. Seeks the PiP to the step start when the user
    /// uses next/prev (or keyboard); playback-driven advances skip seeking
    /// because the timeline is already past that cue.
    private func handleLessonStepAdvance(
        toStepIndex newStepIndex: Int,
        shouldSeekVideoToStepStart: Bool
    ) {
        guard let activeLesson,
              activeLesson.steps.indices.contains(newStepIndex) else {
            return
        }
        let newStep = activeLesson.steps[newStepIndex]
        if shouldSeekVideoToStepStart {
            videoPiPController.seekToTimestamp(
                targetTimeSeconds: newStep.startTimestampSeconds
            )
            persistLessonProgress(
                forLesson: activeLesson,
                atStepIndex: newStepIndex,
                lastTimestampSeconds: newStep.startTimestampSeconds
            )
        } else {
            persistLessonProgress(
                forLesson: activeLesson,
                atStepIndex: newStepIndex,
                lastTimestampSeconds: lastPiPReportedCurrentTimeSeconds
            )
        }
        pointCursorAtRelevantElementForLessonStep(atIndex: newStepIndex)
    }

    /// System prompt for the lightweight Claude call that identifies which
    /// on-screen UI element a lesson step refers to.
    private static let lessonStepPointingSystemPrompt = """
    you are guiding a user through a tutorial. you will receive:
    1. a screenshot of their current screen
    2. the current step instruction from the tutorial

    your ONLY job: call `point_at_element` ONCE on the UI element the \
    instruction refers to. pick the element that best matches what the step \
    is asking the user to click, open, or interact with. use a short 2-4 \
    word label.

    if the instruction is too vague or the element is not visible on screen, \
    call `point_at_element` on the closest match you can find. always call \
    the tool exactly once — never skip it, never call it more than once, \
    and never output any text.
    """

    /// Captures a screenshot and asks Claude to call `point_at_element` on
    /// the UI element the current lesson step instruction refers to. The
    /// buddy cursor then flies to that element just like normal navigation.
    private func pointCursorAtRelevantElementForLessonStep(atIndex stepIndex: Int) {
        lessonStepPointingTask?.cancel()
        lessonStepPointingTask = Task { [weak self] in
            guard let self,
                  !Task.isCancelled,
                  let lesson = self.activeLesson,
                  lesson.steps.indices.contains(stepIndex),
                  self.lessonStateMachine.currentMode == .lesson else {
                return
            }

            let step = lesson.steps[stepIndex]
            let instructionText = step.instructionText.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            let titleText = step.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let userPromptForClaude = instructionText.isEmpty ? titleText : instructionText
            guard !userPromptForClaude.isEmpty else { return }

            do {
                let screenCaptures = try await CompanionScreenCaptureUtility
                    .captureAllScreensAsJPEG()
                guard !Task.isCancelled else { return }

                let labeledImages = screenCaptures.map { capture in
                    let dimensionInfo = " (image dimensions: \(capture.screenshotWidthInPixels)x\(capture.screenshotHeightInPixels) pixels)"
                    return (data: capture.imageData, label: capture.label + dimensionInfo)
                }

                self.clearDetectedElementLocation()
                self.toolRegistry.beginTurn(withScreenCaptures: screenCaptures)
                defer { self.toolRegistry.endTurn() }

                let pointToolOnly = [self.toolRegistry.pointAtElementToolDefinition()]

                let (_, _) = try await self.claudeAPI.analyzeImageStreamingWithTools(
                    images: labeledImages,
                    systemPrompt: Self.lessonStepPointingSystemPrompt,
                    userPrompt: userPromptForClaude,
                    availableTools: pointToolOnly,
                    executeToolCall: { [weak self] toolUseBlock in
                        guard let self else {
                            return ClaudeToolResultBlock(
                                toolUseID: toolUseBlock.id,
                                content: "companion unavailable",
                                isError: true
                            )
                        }
                        return await self.toolRegistry.executeToolCall(toolUseBlock)
                    },
                    onTextChunk: { _ in }
                )
            } catch is CancellationError {
                // Step changed before pointing completed
            } catch {
                print("Lesson step pointing error: \(error)")
            }
        }
    }

    /// Writes the current step + playback timestamp to the SQLite pattern
    /// database so the lesson can be resumed on the next app launch.
    private func persistLessonProgress(
        forLesson lessonToPersist: Lesson,
        atStepIndex stepIndex: Int,
        lastTimestampSeconds: Double
    ) {
        guard isPatternDatabaseOpen else { return }
        patternDatabase.saveLessonProgress(
            youtubeVideoID: lessonToPersist.youtubeVideoID,
            videoTitle: lessonToPersist.videoTitle,
            currentStepIndex: stepIndex,
            totalStepCount: lessonToPersist.steps.count,
            lastTimestampSeconds: lastTimestampSeconds
        )
    }

    /// Finds the step whose time range contains the given playback
    /// timestamp. Used by the PiP delegate to auto-advance the overlay
    /// when playback crosses a step boundary. Returns nil if no step
    /// contains the timestamp (gap between steps).
    private func stepIndexContainingTimestampSeconds(
        timestampSeconds: Double,
        forLesson lessonToSearch: Lesson
    ) -> Int? {
        for (stepIndex, lessonStep) in lessonToSearch.steps.enumerated() {
            if timestampSeconds >= lessonStep.startTimestampSeconds
                && timestampSeconds < lessonStep.endTimestampSeconds {
                return stepIndex
            }
        }
        return nil
    }

    // MARK: - Tutor Mode Idle-Triggered Observations

    let userActivityIdleDetector = UserActivityIdleDetector()
    private var tutorIdleCancellable: AnyCancellable?
    /// Guards against overlapping observations when the idle trigger
    /// fires while a previous observation is still in flight.
    private var isTutorObservationInFlight: Bool = false

    private func startTutorIdleObservation() {
        userActivityIdleDetector.start()
        bindTutorIdleObservation()
    }

    private func stopTutorIdleObservation() {
        tutorIdleCancellable?.cancel()
        tutorIdleCancellable = nil
        userActivityIdleDetector.stop()
        isTutorObservationInFlight = false

        // Tutor observations are spoken directly (no tutor consent prompt),
        // so there's no pending continuation to resolve when tutor mode is
        // disabled mid-observation. The consent controller is still used by
        // AutomationEngine — don't touch it here.
    }

    private func bindTutorIdleObservation() {
        tutorIdleCancellable?.cancel()
        tutorIdleCancellable = userActivityIdleDetector.$isUserIdle
            .filter { $0 == true }
            .sink { [weak self] _ in
                guard let self,
                      self.isTutorModeEnabled,
                      self.voiceState == .idle,
                      !(self.elevenLabsTTSClient.isPlaying),
                      !self.isTutorObservationInFlight else { return }

                // Enforce the per-hour and backoff rate limits before
                // kicking off an observation. The check is cheap — a single
                // SQLite count query — so it's fine to run synchronously.
                guard self.isTutorNudgeAllowedByRateLimit() else {
                    print("🚫 Tutor nudge suppressed by rate limit")
                    return
                }

                self.isTutorObservationInFlight = true
                Task {
                    await self.performTutorObservation()
                    self.userActivityIdleDetector.observationDidComplete()
                    self.isTutorObservationInFlight = false
                }
            }
    }

    /// Whether a tutor nudge is currently allowed. Enforces the PRD's
    /// two-layer rate limit:
    ///   1. Absolute ceiling of 5 nudges per rolling hour.
    ///   2. After 2 consecutive rejections ("n" responses), the ceiling
    ///      drops to 1 nudge per hour until the user accepts a nudge,
    ///      which resets the streak.
    private func isTutorNudgeAllowedByRateLimit() -> Bool {
        guard isPatternDatabaseOpen else {
            // If the DB failed to open, default to allowing nudges so the
            // tutor still works — we just lose rate limiting.
            return true
        }

        let nudgesInLastHour = patternDatabase.tutorNudgeCountInLastHour()
        let consecutiveRejections = patternDatabase.consecutiveRejectedNudgeCount()

        let isUnderBackoff = consecutiveRejections >= Self.consecutiveRejectionsTriggeringBackoff
        let effectiveCeiling = isUnderBackoff
            ? Self.backoffTutorNudgesPerHour
            : Self.maximumTutorNudgesPerHour

        return nudgesInLastHour < effectiveCeiling
    }

    private func performTutorObservation() async {
        do {
            // Ask the user before speaking. The yes/no bubble is
            // non-activating so it doesn't steal focus from their app.
            let frontmostAppForPrompt = NSWorkspace.shared.frontmostApplication?.localizedName ?? "this app"
            let promptResponse = await showProactiveTutorPromptAndAwaitResponse(
                withMessage: "I noticed you paused in \(frontmostAppForPrompt). Want a tip?"
            )

            if promptResponse == .rejected {
                if isPatternDatabaseOpen {
                    patternDatabase.recordTutorNudge(wasAccepted: false)
                }
                userActivityIdleDetector.observationDidComplete()
                return
            }

            if isPatternDatabaseOpen {
                patternDatabase.recordTutorNudge(wasAccepted: true)
            }

            let screenCaptures = try await CompanionScreenCaptureUtility.captureFocusedWindowAsJPEG()
            guard !Task.isCancelled else { return }

            let labeledImages = screenCaptures.map { capture in
                let dimensionInfo = " (image dimensions: \(capture.screenshotWidthInPixels)x\(capture.screenshotHeightInPixels) pixels)"
                return (data: capture.imageData, label: capture.label + dimensionInfo)
            }

            let historyForAPI = conversationHistory.map { entry in
                (userPlaceholder: entry.userTranscript, assistantResponse: entry.assistantResponse)
            }

            // If Wiki Knowledge is enabled, augment the tutor system prompt
            // with relevant wiki context derived from the frontmost app name
            // plus recent conversation turns. Keywords drive index.md matching
            // inside WikiManager.buildContextBundle.
            let tutorSystemPromptWithWikiContext = systemPromptAugmentedWithWikiContext(
                baseSystemPrompt: Self.tutorModeSystemPrompt
            )

            // Prime the tool registry with this turn's screens so the
            // tool executor can resolve `point_at_element` coordinates.
            toolRegistry.beginTurn(withScreenCaptures: screenCaptures)
            defer { toolRegistry.endTurn() }

            let toolsForTutorObservation = toolRegistry.availableToolsForCurrentTurn()

            let (responseText, _) = try await claudeAPI.analyzeImageStreamingWithTools(
                images: labeledImages,
                systemPrompt: tutorSystemPromptWithWikiContext,
                conversationHistory: historyForAPI,
                userPrompt: "observe the screen and guide me",
                availableTools: toolsForTutorObservation,
                executeToolCall: { [weak self] toolUseBlock in
                    guard let self else {
                        return ClaudeToolResultBlock(
                            toolUseID: toolUseBlock.id,
                            content: "companion unavailable",
                            isError: true
                        )
                    }
                    return await self.toolRegistry.executeToolCall(toolUseBlock)
                },
                onTextChunk: { _ in }
            )

            guard !Task.isCancelled else { return }

            let spokenText = responseText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !spokenText.isEmpty else { return }

            // Nudge acceptance/rejection was already recorded at the
            // top of this method via the consent prompt, so we don't
            // record again here.

            if isAutoCopyResponseEnabled {
                ClipboardManager.copyResponseToClipboard(rawResponseText: spokenText)
            }

            conversationHistory.append((
                userTranscript: "[tutor observation]",
                assistantResponse: spokenText
            ))

            if conversationHistory.count > 10 {
                conversationHistory.removeFirst(conversationHistory.count - 10)
            }

            // Tutor observations flow into the session log too so the
            // compressor has full context at session end. The user
            // utterance is the synthetic "[tutor observation]" marker
            // since the tutor isn't responding to a live prompt.
            recordObservedTurn(
                userTranscript: "[tutor observation]",
                assistantResponse: spokenText,
                outputModeUsed: "tutor"
            )

            // Play the response via TTS
            if !spokenText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                voiceState = .responding
                do {
                    try await elevenLabsTTSClient.speakText(spokenText)
                } catch {
                    print("⚠️ Tutor TTS error: \(error)")
                }
                voiceState = .idle
            }

        } catch {
            print("⚠️ Tutor observation error: \(error)")
        }
    }

    // MARK: - Pending Navigation Observation

    /// Kicks off a screenshot-polling loop that watches for meaningful
    /// changes on screen after a navigation response. When the screen
    /// changes (e.g. the user clicks the link Claude pointed to), we ask
    /// Claude for the next step and speak it — no push-to-talk required.
    private func startPendingNavigationObservation(
        afterUserTranscript userTranscript: String,
        afterAssistantResponse assistantResponse: String
    ) {
        pendingNavigationObservationTask?.cancel()
        lastPendingNavigationScreenshotHash = nil
        pendingNavigationUserTranscript = userTranscript
        pendingNavigationAssistantResponse = assistantResponse

        let totalObservationSeconds: Double = 20
        let pollIntervalSeconds: Double = 1.5
        let pollIntervalNanoseconds = UInt64(pollIntervalSeconds * 1_000_000_000)

        pendingNavigationObservationTask = Task { [weak self] in
            guard let self else { return }
            let observationStartDate = Date()

            while !Task.isCancelled {
                let elapsedSeconds = Date().timeIntervalSince(observationStartDate)
                if elapsedSeconds >= totalObservationSeconds { break }

                // Wait before the first capture so the user has time to
                // visibly act on the current step — capturing immediately
                // would just re-hash the same screen we already responded
                // from.
                try? await Task.sleep(nanoseconds: pollIntervalNanoseconds)
                if Task.isCancelled { break }

                // Skip while TTS is playing — we don't want to interrupt
                // the current utterance with a follow-up.
                if self.elevenLabsTTSClient.isPlaying { continue }

                // Skip while the user is speaking or the response pipeline
                // is busy — a new interaction will cancel this task anyway,
                // but we also don't want to race with it.
                guard self.voiceState == .idle else { continue }

                await self.runSinglePendingNavigationTick()
            }

            self.pendingNavigationObservationTask = nil
        }
    }

    /// Cancels the pending-navigation observation loop and clears its state.
    private func stopPendingNavigationObservation() {
        pendingNavigationObservationTask?.cancel()
        pendingNavigationObservationTask = nil
        lastPendingNavigationScreenshotHash = nil
    }

    /// A single iteration of the polling loop: capture a screenshot,
    /// compare its perceptual hash to the previous capture, and ask Claude
    /// for the next step only when the screen meaningfully changed.
    private func runSinglePendingNavigationTick() async {
        let capturedScreens: [CompanionScreenCapture]
        do {
            capturedScreens = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()
        } catch {
            print("⚠️ PendingNavObserver: capture error \(error)")
            return
        }

        // Use the cursor screen as the diff target — that's almost always
        // where the user just acted. Fall back to the first screen if no
        // cursor-screen flag is set.
        guard let primaryCapture = capturedScreens.first(where: { $0.isCursorScreen })
            ?? capturedScreens.first else {
            return
        }

        let previousHash = lastPendingNavigationScreenshotHash
        let changeResult = ScreenshotDiffDetector.didScreenMeaningfullyChange(
            betweenPreviousHash: previousHash,
            andCurrentImageData: primaryCapture.imageData
        )
        lastPendingNavigationScreenshotHash = changeResult.newHash

        // Baseline tick: the very first capture has no prior to compare
        // against. Establish the baseline and wait for the next tick.
        if previousHash == nil { return }

        // No meaningful change — keep polling silently.
        if !changeResult.didChange { return }

        // Screen meaningfully changed — ask Claude for the next step.
        await askClaudeForNextNavigationStep(
            usingCapturedScreens: capturedScreens
        )
    }

    /// Sends the current screen state to Claude with a lightweight
    /// "did the user land on the target? If yes, give the next step"
    /// prompt. Speaks the response via TTS and stays silent if Claude
    /// says the user isn't there yet.
    private func askClaudeForNextNavigationStep(
        usingCapturedScreens capturedScreens: [CompanionScreenCapture]
    ) async {
        let labeledImages = capturedScreens.map { capture in
            let dimensionInfo = " (image dimensions: \(capture.screenshotWidthInPixels)x\(capture.screenshotHeightInPixels) pixels)"
            return (data: capture.imageData, label: capture.label + dimensionInfo)
        }

        let historyForAPI: [(userPlaceholder: String, assistantResponse: String)] = [
            (
                userPlaceholder: pendingNavigationUserTranscript,
                assistantResponse: pendingNavigationAssistantResponse
            )
        ]

        let followUpPrompt = """
        The user just acted on your last navigation response. Look at the \
        current screen. If they're on the target screen or step, give ONLY \
        the single next short step (one sentence) and call \
        `point_at_element` for the element they should interact with next. \
        You may call `query_wiki` if it helps disambiguate app workflow \
        details from the original request. Avoid `start_automation_sequence` \
        and `start_youtube_lesson` unless the original request explicitly \
        asked for those actions. \
        If they're NOT on the target yet, reply with exactly the word \
        "WAIT" and nothing else — do not speak, do not call any tools.
        """

        let followUpSystemPrompt = systemPromptAugmentedWithWikiContext(
            baseSystemPrompt: Self.companionVoiceResponseSystemPromptWithTools,
            additionalKeywords: keywordsFromText(pendingNavigationUserTranscript)
        )

        do {
            voiceState = .processing

            // Prime the registry with this turn's screens so
            // `point_at_element` resolves coordinates correctly.
            toolRegistry.beginTurn(withScreenCaptures: capturedScreens)
            defer { toolRegistry.endTurn() }

            let toolsForPendingNavigationFollowUp = toolRegistry.availableToolsForCurrentTurn()

            let (responseText, _) = try await claudeAPI.analyzeImageStreamingWithTools(
                images: labeledImages,
                systemPrompt: followUpSystemPrompt,
                conversationHistory: historyForAPI,
                userPrompt: followUpPrompt,
                availableTools: toolsForPendingNavigationFollowUp,
                executeToolCall: { [weak self] toolUseBlock in
                    guard let self else {
                        return ClaudeToolResultBlock(
                            toolUseID: toolUseBlock.id,
                            content: "companion unavailable",
                            isError: true
                        )
                    }
                    return await self.toolRegistry.executeToolCall(toolUseBlock)
                },
                onTextChunk: { _ in }
            )

            let spokenText = responseText.trimmingCharacters(in: .whitespacesAndNewlines)
            voiceState = .idle

            // "WAIT" means the screen changed but we're not on the target
            // yet — stay silent and keep polling. Empty replies are
            // treated the same way.
            let upperTrimmed = spokenText.uppercased()
            if spokenText.isEmpty || upperTrimmed == "WAIT" || upperTrimmed.hasPrefix("WAIT") {
                return
            }

            // Update the rolling context so the next tick's follow-up uses
            // the latest step as the assistant-response anchor. Any
            // pointing targets were already published by the tool executor.
            pendingNavigationAssistantResponse = spokenText

            conversationHistory.append((
                userTranscript: "[auto-follow-up]",
                assistantResponse: spokenText
            ))
            if conversationHistory.count > 10 {
                conversationHistory.removeFirst(conversationHistory.count - 10)
            }

            voiceState = .responding
            do {
                try await elevenLabsTTSClient.speakText(spokenText)
            } catch {
                print("⚠️ PendingNavObserver: TTS error \(error)")
            }
            voiceState = .idle
        } catch {
            print("⚠️ PendingNavObserver: Claude error \(error)")
            voiceState = .idle
        }
    }

    /// Derives a short teaser from the full tutor observation text suitable
    /// for the proactive prompt bubble. Long observations would cramp the
    /// bubble and defeat the point of a quick y/n gate — we want the user
    /// to decide in under a second.
    ///
    /// Strategy: take the first sentence, then fall back to a character-
    /// count truncation if the first sentence itself is too long.
    private func briefProactiveTutorPromptTeaser(
        fullObservationText: String
    ) -> String {
        let maximumTeaserCharacterCount = 140

        let trimmedFullText = fullObservationText
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedFullText.isEmpty else {
            return "Want a quick tip about what you're doing?"
        }

        // Find the end of the first sentence (period/question/exclamation +
        // optional trailing whitespace).
        if let firstSentenceEndIndex = trimmedFullText.range(
            of: "[.!?]\\s*",
            options: .regularExpression
        )?.upperBound {
            let firstSentence = String(trimmedFullText[..<firstSentenceEndIndex])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !firstSentence.isEmpty && firstSentence.count <= maximumTeaserCharacterCount {
                return firstSentence
            }
        }

        // Fallback: truncate to the character limit on a word boundary.
        if trimmedFullText.count <= maximumTeaserCharacterCount {
            return trimmedFullText
        }
        let truncationEndIndex = trimmedFullText.index(
            trimmedFullText.startIndex,
            offsetBy: maximumTeaserCharacterCount
        )
        let truncatedText = String(trimmedFullText[..<truncationEndIndex])
        if let lastSpaceIndex = truncatedText.lastIndex(of: " ") {
            return String(truncatedText[..<lastSpaceIndex]) + "…"
        }
        return truncatedText + "…"
    }

    /// Returns the given base system prompt with wiki context appended when
    /// `isWikiKnowledgeEnabled` is true and the wiki has relevant pages. The
    /// context bundle is pulled from WikiManager using keywords derived from
    /// the frontmost app and any additional caller-supplied keywords.
    ///
    /// When wiki knowledge is disabled, the DB failed to open, or no pages
    /// match, the base system prompt is returned unchanged so behavior stays
    /// identical to the pre-wiki path.
    private func systemPromptAugmentedWithWikiContext(
        baseSystemPrompt: String,
        additionalKeywords: [String] = []
    ) -> String {
        guard isWikiKnowledgeEnabled, wikiManager.isInitialized else {
            return baseSystemPrompt
        }

        let frontmostAppName = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
        var keywordsForMatching: [String] = []
        if !frontmostAppName.isEmpty {
            keywordsForMatching.append(frontmostAppName)
        }
        keywordsForMatching.append(contentsOf: additionalKeywords)

        guard !keywordsForMatching.isEmpty else {
            return baseSystemPrompt
        }

        let wikiQueryResult = wikiQueryEngine.buildContextBundle(
            forTopicKeywords: keywordsForMatching,
            maxCharacters: 4000
        )
        lastWikiPagesConsulted = wikiQueryResult.includedPageFilenames
        let wikiContextBundle = wikiQueryResult.contextBundle
        guard !wikiContextBundle.isEmpty else {
            return baseSystemPrompt
        }

        return """
            \(baseSystemPrompt)

            --- User's Prior Knowledge Wiki ---
            The user has the following personal wiki pages relevant to this context.
            Use these as background knowledge when forming your response. Do not
            mention the wiki explicitly — treat the information as something you
            already know about the user's workflow.

            \(wikiContextBundle)
            --- End Wiki Context ---
            """
    }

    // MARK: - Session Observation

    /// Records one user↔assistant turn to the session observer. Lazy-creates
    /// the observer on first use so sessions are bounded by actual user
    /// interaction (not app launch). The observer writes to disk and keeps
    /// an in-memory copy for later compression.
    ///
    /// Callers should provide the router's chosen output mode so the session
    /// log captures which surface rendered each response — useful signal for
    /// the compressor and for future queries.
    func recordObservedTurn(
        userTranscript: String,
        assistantResponse: String,
        outputModeUsed: String
    ) {
        // Detect outcome of the previous turn based on what the user
        // says now (gratitude = success, re-ask = failure, etc.).
        recordOutcomeForPreviousTurnIfApplicable(
            currentUserTranscript: userTranscript
        )
        previousTurnUserTranscript = userTranscript

        let observer = currentSessionObserverAgent ?? startNewSessionObserverAgent()
        currentSessionObserverAgent = observer
        lastSessionInteractionTimestamp = Date()

        let frontmostAppName = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
        observer.observeTurn(
            userUtterance: userTranscript,
            assistantResponse: assistantResponse,
            frontmostAppName: frontmostAppName,
            outputModeUsed: outputModeUsed
        )

        if isPatternDatabaseOpen, let sessionID = currentPatternDatabaseSessionID {
            patternDatabase.recordInteraction(sessionID: sessionID)
        }

        autoResearchFrontmostAppIfUnknown()
    }

    /// Creates a new observer, ensuring the wiki is initialized first so the
    /// raw/sessions/ directory exists before the session file is written.
    private func startNewSessionObserverAgent() -> ObserverAgent {
        if !wikiManager.isInitialized {
            wikiManager.initializeIfNeeded()
        }
        let observer = ObserverAgent(
            wikiManager: wikiManager,
            sessionCompressor: sessionCompressor
        )

        if isPatternDatabaseOpen {
            currentPatternDatabaseSessionID = patternDatabase.startSession()
        }

        print("🔎 ObserverAgent: started new session \(observer.sessionMetadata.sessionIdentifier)")
        return observer
    }

    /// Ends the current session (if any) and compresses it into a wiki
    /// page. Records the session's end time in UserDefaults so the next
    /// launch can decide whether to generate a cold-start recap. Safe to
    /// call multiple times — subsequent calls no-op.
    func endCurrentSessionAndCompressForObserver() async {
        guard let observer = currentSessionObserverAgent else { return }
        currentSessionObserverAgent = nil

        if isPatternDatabaseOpen, let sessionID = currentPatternDatabaseSessionID {
            patternDatabase.endSession(sessionID: sessionID)
            currentPatternDatabaseSessionID = nil
        }

        let sessionLogFilename = observer.sessionLogFilename
        UserDefaults.standard.set(
            Date().timeIntervalSince1970,
            forKey: Self.lastSessionEndedAtUserDefaultsKey
        )
        UserDefaults.standard.set(
            sessionLogFilename,
            forKey: Self.lastSessionLogFilenameUserDefaultsKey
        )

        await observer.endSessionAndCompress()

        // After compression writes a new session page, check if it
        // overlaps with existing pages and merge if so. This runs in the
        // background since it's not time-sensitive.
        let sessionPageFilename = "session-\(observer.sessionMetadata.sessionIdentifier).md"
        Task { [weak self] in
            await self?.wikiPageConsolidator.consolidateIfDuplicatesExist(
                forPageFilename: sessionPageFilename
            )
        }
    }

    // MARK: - Cold Start Recap

    /// If the user has returned after a long gap (see
    /// `coldStartSessionGapThresholdSeconds`), asks the session compressor
    /// to summarize the prior session file. Stores the recap string on
    /// `pendingColdStartRecapText` for the UI/overlay to surface when ready.
    ///
    /// No-op when there's no prior session recorded, or the gap is short
    /// enough that the user is almost certainly continuing what they were
    /// doing.
    func generateColdStartRecapIfEligible() async {
        let lastEndedEpoch = UserDefaults.standard.double(forKey: Self.lastSessionEndedAtUserDefaultsKey)
        guard lastEndedEpoch > 0 else { return }

        let secondsSinceLastSession = Date().timeIntervalSince1970 - lastEndedEpoch
        guard secondsSinceLastSession >= Self.coldStartSessionGapThresholdSeconds else { return }

        guard let lastSessionFilename = UserDefaults.standard.string(
            forKey: Self.lastSessionLogFilenameUserDefaultsKey
        ) else { return }

        let priorSessionFileURL = wikiManager.rawSessionsDirectoryURL
            .appendingPathComponent(lastSessionFilename)
        guard FileManager.default.fileExists(atPath: priorSessionFileURL.path) else { return }

        if let recapText = await sessionCompressor.generateColdStartRecap(
            fromMostRecentSessionFileURL: priorSessionFileURL
        ) {
            pendingColdStartRecapText = recapText
            print("🔎 ColdStartRecap: \(recapText)")
        }
    }

    /// Recap text generated for the current session. The overlay or chat
    /// window surfaces this on first interaction and clears it afterward.
    @Published var pendingColdStartRecapText: String?

    // MARK: - Proactive Auto-Research

    /// Apps that have already been auto-researched this session, so we
    /// don't re-trigger on every interaction with the same app.
    private var appsAlreadyAutoResearched: Set<String> = []

    /// Timestamps of recent auto-research operations, used to enforce
    /// the hourly rate limit.
    private var autoResearchTimestamps: [Date] = []

    /// Maximum background auto-research operations per rolling hour.
    private static let maximumAutoResearchPerHour: Int = 3

    /// macOS system apps that should never trigger auto-research because
    /// they're infrastructure, not tools the user needs help with.
    private static let autoResearchAppDenylist: Set<String> = [
        "Finder", "loginwindow", "SystemUIServer", "Dock",
        "Control Center", "Notification Center", "Spotlight",
        "WindowManager", "AirPlayUIAgent", "Siri", "Wallpaper",
        "universalaccessd", "TextInputMenuAgent"
    ]

    /// Checks whether the current frontmost app is unknown to the wiki
    /// and, if so, triggers a background research + compress pipeline so
    /// the wiki has context available for the user's next question.
    private func autoResearchFrontmostAppIfUnknown() {
        guard isWikiKnowledgeEnabled, wikiManager.isInitialized else { return }

        guard let frontmostAppName = NSWorkspace.shared.frontmostApplication?.localizedName,
              !frontmostAppName.isEmpty,
              !Self.autoResearchAppDenylist.contains(frontmostAppName),
              !appsAlreadyAutoResearched.contains(frontmostAppName) else {
            return
        }

        // Mark as researched immediately to prevent re-triggering while
        // the background task is still running.
        appsAlreadyAutoResearched.insert(frontmostAppName)

        let existingPages = wikiQueryEngine.findRelevantPages(
            matchingKeywords: [frontmostAppName],
            maxPagesToReturn: 1
        )
        guard existingPages.isEmpty else { return }

        guard isAutoResearchWithinHourlyRateLimit() else {
            print("📚 Auto-research skipped for \(frontmostAppName) — hourly rate limit reached")
            return
        }

        autoResearchTimestamps.append(Date())

        print("📚 Auto-researching unknown app: \(frontmostAppName)")
        Task { [weak self] in
            guard let self else { return }
            do {
                let ingestedSources = try await self.autoResearchPipeline.ingestTopic(frontmostAppName)
                guard !ingestedSources.isEmpty else { return }
                await self.researchSourceCompressor.compressResearchSourcesIntoWikiPage(
                    forTopic: frontmostAppName,
                    ingestedRawSources: ingestedSources
                )
                print("📚 Auto-research complete for \(frontmostAppName): \(ingestedSources.count) sources ingested")
            } catch {
                print("📚 Auto-research failed for \(frontmostAppName): \(error)")
            }
        }
    }

    /// Returns true if fewer than `maximumAutoResearchPerHour` research
    /// operations have been triggered in the last 60 minutes.
    private func isAutoResearchWithinHourlyRateLimit() -> Bool {
        let oneHourAgo = Date().addingTimeInterval(-3600)
        autoResearchTimestamps.removeAll { $0 < oneHourAgo }
        return autoResearchTimestamps.count < Self.maximumAutoResearchPerHour
    }

    // MARK: - Interaction Outcome Detection

    /// Coarse signal about whether a user interaction succeeded or failed,
    /// derived from heuristics on the user's follow-up transcript.
    enum InteractionOutcome: String {
        case likelySuccess
        case likelyFailure
        case neutral
    }

    /// The user's transcript from the previous turn, used to detect
    /// repeated questions (a failure signal).
    private var previousTurnUserTranscript: String?

    /// Wiki page filenames that were included in the most recent context
    /// bundle, so outcome tracking can attribute success/failure to
    /// specific pages.
    private var lastWikiPagesConsulted: [String] = []

    /// Detects whether the current interaction suggests the previous one
    /// succeeded or failed. Uses simple text heuristics — no NLP required.
    private func detectInteractionOutcome(
        currentUserTranscript: String
    ) -> InteractionOutcome {
        let lowercased = currentUserTranscript.lowercased()

        let successPhrases = [
            "thanks", "thank you", "perfect", "got it", "awesome",
            "great", "that worked", "nice", "exactly", "yes that's right"
        ]
        for phrase in successPhrases {
            if lowercased.contains(phrase) { return .likelySuccess }
        }

        let failurePhrases = [
            "that's wrong", "didn't work", "not what i", "try again",
            "that's not right", "no that's", "wrong", "doesn't work",
            "still not", "that's incorrect"
        ]
        for phrase in failurePhrases {
            if lowercased.contains(phrase) { return .likelyFailure }
        }

        // Repeated question detection: if the current transcript is very
        // similar to the previous one, the user is re-asking.
        if let previousTranscript = previousTurnUserTranscript {
            let previousWords = Set(previousTranscript.lowercased().split(separator: " "))
            let currentWords = Set(lowercased.split(separator: " "))
            let intersection = previousWords.intersection(currentWords)
            let unionCount = max(1, previousWords.union(currentWords).count)
            let jaccardSimilarity = Double(intersection.count) / Double(unionCount)
            if jaccardSimilarity > 0.7 { return .likelyFailure }
        }

        return .neutral
    }

    /// Records the interaction outcome for the previous turn. Called at
    /// the start of each new turn so the user's follow-up provides the
    /// signal about whether the prior answer helped.
    private func recordOutcomeForPreviousTurnIfApplicable(
        currentUserTranscript: String
    ) {
        guard isPatternDatabaseOpen,
              previousTurnUserTranscript != nil else { return }

        let outcome = detectInteractionOutcome(
            currentUserTranscript: currentUserTranscript
        )
        guard outcome != .neutral else { return }

        let frontmostApp = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
        let sessionID = currentSessionObserverAgent?.sessionMetadata.sessionIdentifier ?? ""
        let consultedPages = lastWikiPagesConsulted.joined(separator: ",")

        patternDatabase.recordInteractionOutcome(
            sessionID: sessionID,
            topicKeywords: previousTurnUserTranscript ?? "",
            frontmostApp: frontmostApp,
            outcome: outcome.rawValue,
            wikiPagesConsulted: consultedPages
        )

        // Adjust confidence for wiki pages that were consulted during the
        // interaction whose outcome we just recorded. Success boosts
        // confidence; failure decreases it. Time-based decay in
        // getConfidenceScore ensures old adjustments fade naturally.
        let confidenceAdjustment: Double = (outcome == .likelySuccess) ? 0.05 : -0.05
        for pageFilename in lastWikiPagesConsulted {
            let currentConfidence = patternDatabase.getConfidenceScore(
                wikiPageFilename: pageFilename
            ) ?? 0.7
            let adjustedConfidence = max(0.0, min(1.0, currentConfidence + confidenceAdjustment))
            patternDatabase.saveConfidenceScore(
                wikiPageFilename: pageFilename,
                confidenceScore: adjustedConfidence,
                sourceCount: 1
            )
        }
    }

    /// Short tool/framework names that must survive keyword filtering even
    /// though they're under 3 characters. Without this, queries about
    /// "Git", "Go", "npm", etc. would produce zero wiki hits.
    private static let shortToolNamesAllowlist: Set<String> = [
        "git", "go", "npm", "vim", "vs", "ai", "css", "sql", "api",
        "aws", "gcp", "cli", "ssh", "tls", "jwt", "ui", "ux", "ci",
        "cd", "db", "os", "ip", "id"
    ]

    /// Common English words that should be filtered from keyword lists
    /// even though they're longer than 3 characters. These match too
    /// broadly and pollute wiki search results.
    private static let keywordStopWords: Set<String> = [
        "want", "make", "this", "that", "have", "from", "with", "what",
        "when", "where", "which", "will", "would", "could", "should",
        "about", "into", "your", "just", "like", "been", "some", "than",
        "them", "then", "they", "were", "does", "done", "also", "each",
        "very", "much", "here", "there", "more", "most", "only", "over",
        "help", "need", "know", "tell", "show", "going", "really",
        "thing", "things", "using", "used", "able", "please", "can't",
        "don't", "it's", "i'm"
    ]

    /// Extracts keywords from text for wiki index matching. Keeps words
    /// longer than 3 characters (minus stop words) and short words that
    /// appear in the tools allowlist. Also extracts noun phrases from
    /// common question patterns like "how to use X" or "what is X".
    private func keywordsFromText(_ text: String) -> [String] {
        let lowercased = text.lowercased()
        let whitespaceSeparatedWords = lowercased
            .components(separatedBy: .whitespacesAndNewlines)

        var keywords: [String] = []
        for word in whitespaceSeparatedWords {
            let trimmed = word.trimmingCharacters(in: .punctuationCharacters)
            guard !trimmed.isEmpty else { continue }

            if Self.shortToolNamesAllowlist.contains(trimmed) {
                keywords.append(trimmed)
            } else if trimmed.count > 3 && !Self.keywordStopWords.contains(trimmed) {
                keywords.append(trimmed)
            }
        }

        // Extract noun phrases from common question patterns so "how to
        // use Figma" yields "figma" as a high-priority keyword.
        let questionPatterns = [
            "how to use ([a-zA-Z0-9_-]+)",
            "how do (?:i|you) (?:use|open|start|set up) ([a-zA-Z0-9_-]+)",
            "what is ([a-zA-Z0-9_-]+)",
            "help with ([a-zA-Z0-9_-]+)",
            "learn ([a-zA-Z0-9_-]+)"
        ]
        for pattern in questionPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                let fullRange = NSRange(lowercased.startIndex..., in: lowercased)
                let matches = regex.matches(in: lowercased, range: fullRange)
                for match in matches {
                    if match.numberOfRanges >= 2,
                       let captureRange = Range(match.range(at: 1), in: lowercased) {
                        let captured = String(lowercased[captureRange])
                        if !keywords.contains(captured) {
                            keywords.append(captured)
                        }
                    }
                }
            }
        }

        return keywords
    }

    /// Returns true when the user's transcript looks like a math problem
    /// the assistant should solve with step-by-step typeset LaTeX rather
    /// than natural-speech prose.
    ///
    /// Detection is intentionally loose — a false positive just swaps the
    /// system prompt and the response routes to the answer panel (worst
    /// case: a non-math question gets a rigorous layout). A false negative
    /// sends the user back to prose math, which is the exact regression
    /// we're trying to avoid.
    private func containsMathIntent(inUserQuestion userQuestion: String) -> Bool {
        let lowercasedQuestion = userQuestion.lowercased()

        // Strong math keyword verbs / nouns. Any one of these (with the
        // ambiguous ones gated on a syntax signal) flips the turn into
        // math mode.
        let strongMathKeywords: [String] = [
            "solve", "simplify", "factor", "integral", "integrate",
            "derivative", "differentiate", "limit of",
            "equation", "expression", "polynomial", "quadratic",
            "find x", "find y", "find the value",
            "prove", "show that"
        ]
        for strongKeyword in strongMathKeywords {
            if lowercasedQuestion.contains(strongKeyword) {
                return true
            }
        }

        // Ambiguous keywords that only signal math when paired with a
        // syntactic hint (digits, operators, variables, exponents).
        // "compute hello world" should stay conversational; "compute
        // 3x^2 + 2" should become math.
        let ambiguousMathKeywords: [String] = [
            "compute", "calculate", "evaluate",
            "what is the", "what's the"
        ]
        for ambiguousKeyword in ambiguousMathKeywords {
            if lowercasedQuestion.contains(ambiguousKeyword)
                && hasMathSyntaxSignal(inLowercasedText: lowercasedQuestion) {
                return true
            }
        }

        return hasMathSyntaxSignal(inLowercasedText: lowercasedQuestion)
    }

    /// Secondary signal: the lowercased transcript contains math-operator
    /// structure (digits + operator, `x^2`, `sqrt`, `equals` between
    /// symbolic tokens, spoken exponents like "squared").
    private func hasMathSyntaxSignal(inLowercasedText lowercasedText: String) -> Bool {
        // `x^2`, `y^3`, etc.
        if lowercasedText.range(
            of: "[a-z]\\s*\\^\\s*\\d",
            options: .regularExpression
        ) != nil { return true }

        // Spoken exponents: "x squared", "cubed", "to the power".
        if lowercasedText.contains("squared")
            || lowercasedText.contains("cubed")
            || lowercasedText.contains("to the power") {
            return true
        }

        // Roots: "sqrt", "square root".
        if lowercasedText.contains("square root")
            || lowercasedText.contains("sqrt") {
            return true
        }

        // Digit + operator + digit-or-variable, e.g. `3x + 2 = 5`, `2*3`,
        // `4/5`. Matches most typed equations.
        if lowercasedText.range(
            of: "\\d\\s*[+\\-*/=]\\s*[\\da-z]",
            options: .regularExpression
        ) != nil { return true }

        // Spoken equations: "3x equals 5", "y equals 2x".
        if lowercasedText.range(
            of: "[a-z\\d]\\s+equals\\s+[a-z\\d]",
            options: .regularExpression
        ) != nil { return true }

        return false
    }

    /// Bridges the callback-based prompt controller into async/await so the
    /// tutor observation flow can linearly await the user's decision.
    private func showProactiveTutorPromptAndAwaitResponse(
        withMessage promptMessage: String
    ) async -> ProactiveTutorPromptResponse {
        await withCheckedContinuation { continuation in
            proactiveTutorPromptController.showPrompt(
                withMessage: promptMessage,
                onResponse: { response in
                    continuation.resume(returning: response)
                }
            )
        }
    }

    /// Speaks a hardcoded error message using macOS system TTS when API
    /// credits run out. Uses NSSpeechSynthesizer so it works even when
    /// ElevenLabs is down.
    private func speakCreditsErrorFallback() {
        let utterance = "You have run out of API credits."
        let synthesizer = NSSpeechSynthesizer()
        synthesizer.startSpeaking(utterance)
        voiceState = .responding
    }

    // MARK: - Pointing Coordinate Resolution

    /// A coordinate the `point_at_element` tool executor has already
    /// validated — screenshot-pixel x/y, optional screen number, and a
    /// short label. Used as the input to `buildPointingTarget(...)`
    /// which maps it into global AppKit space for the overlay.
    struct PointingMatch: Equatable {
        /// Pixel coordinate in screenshot space. Non-optional in the
        /// tool-use era — the executor refuses to build a PointingMatch
        /// without a real coordinate.
        let coordinate: CGPoint?
        /// Short human-readable label shown next to the cursor
        /// (e.g. "run button").
        let elementLabel: String?
        /// Screen number (1-based) the coordinate refers to, or nil to
        /// default to the cursor's current screen.
        let screenNumber: Int?
    }

    /// Converts a `PointingMatch` (produced by the `point_at_element`
    /// tool executor from Claude's tool-use arguments) into a
    /// `PointingTarget` usable by the overlay. Handles screenshot-pixel
    /// → display-point scaling and the top-left → bottom-left
    /// coordinate flip, so every tool-driven path (main response, tutor,
    /// follow-up, onboarding demo) shares one coordinate-mapping
    /// implementation.
    ///
    /// - Parameter match: The coordinate payload from the tool call.
    ///   Returns nil if the coordinate is missing or the screen number
    ///   is out of range.
    /// - Parameter availableScreenCaptures: Screen captures produced for
    ///   the current turn. Used to look up the destination screen by
    ///   1-based `screenNumber`, falling back to the cursor screen.
    /// - Parameter labelTextOverride: When non-nil, overrides the match's
    ///   element label (used by the onboarding demo so the pointer
    ///   bubble reads as the full spoken observation instead of the
    ///   short label Claude emitted).
    static func buildPointingTarget(
        fromMatch match: PointingMatch,
        availableScreenCaptures: [CompanionScreenCapture],
        labelTextOverride: String? = nil
    ) -> PointingTarget? {
        guard let pointCoordinate = match.coordinate else { return nil }

        let targetScreenCapture: CompanionScreenCapture? = {
            if let screenNumber = match.screenNumber,
               screenNumber >= 1 && screenNumber <= availableScreenCaptures.count {
                return availableScreenCaptures[screenNumber - 1]
            }
            return availableScreenCaptures.first(where: { $0.isCursorScreen })
                ?? availableScreenCaptures.first
        }()

        guard let targetScreenCapture else { return nil }

        // Claude's coordinates are in screenshot pixel space (top-left
        // origin). Scale to the display's point space, then flip Y and
        // translate into global AppKit coords so BlueCursorView can fly
        // the buddy there.
        let screenshotWidth = CGFloat(targetScreenCapture.screenshotWidthInPixels)
        let screenshotHeight = CGFloat(targetScreenCapture.screenshotHeightInPixels)
        let displayWidth = CGFloat(targetScreenCapture.displayWidthInPoints)
        let displayHeight = CGFloat(targetScreenCapture.displayHeightInPoints)
        let displayFrame = targetScreenCapture.displayFrame

        let clampedX = max(0, min(pointCoordinate.x, screenshotWidth))
        let clampedY = max(0, min(pointCoordinate.y, screenshotHeight))

        let displayLocalX = clampedX * (displayWidth / screenshotWidth)
        let displayLocalY = clampedY * (displayHeight / screenshotHeight)
        let appKitY = displayHeight - displayLocalY

        let globalLocation = CGPoint(
            x: displayLocalX + displayFrame.origin.x,
            y: appKitY + displayFrame.origin.y
        )

        let labelText = labelTextOverride ?? match.elementLabel ?? ""
        return PointingTarget(
            screenLocation: globalLocation,
            displayFrame: displayFrame,
            labelText: labelText
        )
    }

    // MARK: - Onboarding Video

    /// Sets up the onboarding video player, starts playback, and schedules
    /// the demo interaction at 40s. Called by BlueCursorView when onboarding starts.
    func setupOnboardingVideo() {
        guard let videoURL = URL(string: "https://stream.mux.com/e5jB8UuSrtFABVnTHCR7k3sIsmcUHCyhtLu1tzqLlfs.m3u8") else { return }

        let player = AVPlayer(url: videoURL)
        player.isMuted = false
        player.volume = 0.0
        self.onboardingVideoPlayer = player
        self.showOnboardingVideo = true
        self.onboardingVideoOpacity = 0.0

        // Start playback immediately — the video plays while invisible,
        // then we fade in both the visual and audio over 1s.
        player.play()

        // Wait for SwiftUI to mount the view, then set opacity to 1.
        // The .animation modifier on the view handles the actual animation.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            self.onboardingVideoOpacity = 1.0
            // Fade audio volume from 0 → 1 over 2s to match visual fade
            self.fadeInVideoAudio(player: player, targetVolume: 1.0, duration: 2.0)
        }

        // At 40 seconds into the video, trigger the onboarding demo where
        // ClaudeCursor flies to something interesting on screen and comments on it
        let demoTriggerTime = CMTime(seconds: 40, preferredTimescale: 600)
        onboardingDemoTimeObserver = player.addBoundaryTimeObserver(
            forTimes: [NSValue(time: demoTriggerTime)],
            queue: .main
        ) { [weak self] in
            ClaudeCursorAnalytics.trackOnboardingDemoTriggered()
            self?.performOnboardingDemoInteraction()
        }

        // Fade out and clean up when the video finishes
        onboardingVideoEndObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: player.currentItem,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            ClaudeCursorAnalytics.trackOnboardingVideoCompleted()
            self.onboardingVideoOpacity = 0.0
            // Wait for the 2s fade-out animation to complete before tearing down
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                self.tearDownOnboardingVideo()
                // After the video disappears, stream in the prompt to try talking
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    self.startOnboardingPromptStream()
                }
            }
        }
    }

    func tearDownOnboardingVideo() {
        showOnboardingVideo = false
        if let timeObserver = onboardingDemoTimeObserver {
            onboardingVideoPlayer?.removeTimeObserver(timeObserver)
            onboardingDemoTimeObserver = nil
        }
        onboardingVideoPlayer?.pause()
        onboardingVideoPlayer = nil
        if let observer = onboardingVideoEndObserver {
            NotificationCenter.default.removeObserver(observer)
            onboardingVideoEndObserver = nil
        }
    }

    private func startOnboardingPromptStream() {
        let message = "press control + option and introduce yourself"
        onboardingPromptText = ""
        showOnboardingPrompt = true
        onboardingPromptOpacity = 0.0

        withAnimation(.easeIn(duration: 0.4)) {
            onboardingPromptOpacity = 1.0
        }

        var currentIndex = 0
        Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { timer in
            guard currentIndex < message.count else {
                timer.invalidate()
                // Auto-dismiss after 10 seconds
                DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) {
                    guard self.showOnboardingPrompt else { return }
                    withAnimation(.easeOut(duration: 0.3)) {
                        self.onboardingPromptOpacity = 0.0
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        self.showOnboardingPrompt = false
                        self.onboardingPromptText = ""
                    }
                }
                return
            }
            let index = message.index(message.startIndex, offsetBy: currentIndex)
            self.onboardingPromptText.append(message[index])
            currentIndex += 1
        }
    }

    /// Gradually raises an AVPlayer's volume from its current level to the
    /// target over the specified duration, creating a smooth audio fade-in.
    private func fadeInVideoAudio(player: AVPlayer, targetVolume: Float, duration: Double) {
        let steps = 20
        let stepInterval = duration / Double(steps)
        let volumeIncrement = (targetVolume - player.volume) / Float(steps)
        var stepsRemaining = steps

        Timer.scheduledTimer(withTimeInterval: stepInterval, repeats: true) { timer in
            stepsRemaining -= 1
            player.volume += volumeIncrement

            if stepsRemaining <= 0 {
                timer.invalidate()
                player.volume = targetVolume
            }
        }
    }

    // MARK: - Onboarding Demo Interaction

    private static let onboardingDemoSystemPrompt = """
    you're claude cursor, a small cursor buddy living on the user's screen. you're showing off during onboarding — look at their screen and find ONE specific, concrete thing to point at. pick something with a clear name or identity: a specific app icon (say its name), a specific word or phrase of text you can read, a specific filename, a specific button label, a specific tab title, a specific image you can describe. do NOT point at vague things like "a window" or "some text" — be specific about exactly what you see.

    CALL THE `point_at_element` TOOL EXACTLY ONCE with x, y, and a short 3-6 word quirky label. the label is what shows next to the cursor — something fun, playful, or curious that shows you actually read/recognized it. no emojis. NEVER quote or repeat text you see on screen verbatim — just react to it. 6 words max in the label.

    CRITICAL COORDINATE RULE: only pick elements near the CENTER of the screen. your x coordinate MUST be between 20%-80% of the image width. your y coordinate MUST be between 20%-80% of the image height. do NOT pick anything in the top 20%, bottom 20%, left 20%, or right 20% — no menu bar items, no dock icons, no sidebar items, no items near any edge. only things clearly in the middle area. if the only interesting things are near the edges, pick something boring in the center instead.

    the screenshot images are labeled with their pixel dimensions. use those dimensions as the coordinate space. origin (0,0) is top-left. x increases rightward, y increases downward.
    onboarding guardrail: for this demo, use ONLY `point_at_element`. do NOT call `open_answer_panel`, `query_wiki`, `copy_response_to_clipboard`, `start_youtube_lesson`, or `start_automation_sequence`.
    after calling `point_at_element`, end your turn — no prose, no extra text.
    """

    /// Captures a screenshot and asks Claude to find something interesting to
    /// point at, then triggers the buddy's flight animation. Used during
    /// onboarding to demo the pointing feature while the intro video plays.
    ///
    /// Claude picks the target via native tool-use (`point_at_element`) —
    /// the tool executor in `CompanionToolRegistry` publishes the resolved
    /// `PointingTarget` directly to `activePointingTargets`, so there's no
    /// follow-up text parsing step here.
    func performOnboardingDemoInteraction() {
        // Don't interrupt an active voice response
        guard voiceState == .idle || voiceState == .responding else { return }

        Task { @MainActor in
            do {
                let screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()

                // Only send the cursor screen so Claude can't pick something
                // on a different monitor that we can't point at.
                guard let cursorScreenCapture = screenCaptures.first(where: { $0.isCursorScreen }) else {
                    print("🎯 Onboarding demo: no cursor screen found")
                    return
                }

                let dimensionInfo = " (image dimensions: \(cursorScreenCapture.screenshotWidthInPixels)x\(cursorScreenCapture.screenshotHeightInPixels) pixels)"
                let labeledImages = [(data: cursorScreenCapture.imageData, label: cursorScreenCapture.label + dimensionInfo)]

                // Prime the registry with just this one screen so
                // `point_at_element` resolves coordinates against the
                // onboarding demo screenshot.
                toolRegistry.beginTurn(withScreenCaptures: [cursorScreenCapture])
                defer { toolRegistry.endTurn() }

                let toolsForOnboardingDemo = toolRegistry.availableToolsForCurrentTurn()

                _ = try await claudeAPI.analyzeImageStreamingWithTools(
                    images: labeledImages,
                    systemPrompt: Self.onboardingDemoSystemPrompt,
                    userPrompt: "look around my screen and find something interesting to point at",
                    availableTools: toolsForOnboardingDemo,
                    executeToolCall: { [weak self] toolUseBlock in
                        guard let self else {
                            return ClaudeToolResultBlock(
                                toolUseID: toolUseBlock.id,
                                content: "companion unavailable",
                                isError: true
                            )
                        }
                        return await self.toolRegistry.executeToolCall(toolUseBlock)
                    },
                    onTextChunk: { _ in }
                )
            } catch {
                print("⚠️ Onboarding demo error: \(error)")
            }
        }
    }
}

// MARK: - VideoPiPControllerDelegate

extension CompanionManager: VideoPiPControllerDelegate {

    /// Called ~4x per second while the PiP video is playing. If playback
    /// crosses into a step that isn't the current one, auto-advance the
    /// overlay so the user's reading material stays in sync with the
    /// video without them having to click "Next" every time.
    func videoPiPController(
        _ controller: VideoPiPController,
        didReportCurrentTimeSeconds currentTimeSeconds: Double
    ) {
        if activeLesson != nil {
            lastPiPReportedCurrentTimeSeconds = currentTimeSeconds
        }
        guard let currentActiveLesson = activeLesson,
              lessonOverlayController.isLessonOverlayVisible else {
            return
        }

        guard let stepIndexContainingCurrentTime = stepIndexContainingTimestampSeconds(
            timestampSeconds: currentTimeSeconds,
            forLesson: currentActiveLesson
        ) else {
            return
        }

        let currentOverlayStepIndex = lessonOverlayController
            .lessonOverlayViewModel.currentStepIndex

        // Only auto-advance forward — jumping backwards when a user is
        // manually scrubbing would fight with their input.
        if stepIndexContainingCurrentTime > currentOverlayStepIndex {
            lessonOverlayController.advanceToStep(
                atIndex: stepIndexContainingCurrentTime
            )
            // Step-change handler skips seek — playback is already inside
            // the new step — but still persists via last reported time.
        } else {
            // Even without a step advance, persist the current playback
            // position periodically so "resume" picks up mid-step after
            // the user closes and reopens the lesson. Throttled via
            // `persistIfThrottled` to avoid a write every 250ms.
            persistCurrentLessonTimestampIfThrottled(
                lesson: currentActiveLesson,
                stepIndex: currentOverlayStepIndex,
                timestampSeconds: currentTimeSeconds
            )
        }
    }

    /// Called when the YouTube IFrame player changes state. We only care
    /// about `.ended` — marking the lesson complete so the next open
    /// restarts from step 0 rather than opening at the last step.
    func videoPiPController(
        _ controller: VideoPiPController,
        didChangePlaybackState newPlaybackState: VideoPiPPlaybackState
    ) {
        guard newPlaybackState == .ended,
              let completedLesson = activeLesson,
              !completedLesson.steps.isEmpty else {
            return
        }
        // Persist as "completed" by recording the last step index. The
        // `isCompleted` derived property on LessonProgressRecord will then
        // return true and the next extraction will resume at step 0.
        let finalStepIndex = completedLesson.steps.count - 1
        let finalStepEndTimestamp = completedLesson.steps[finalStepIndex].endTimestampSeconds
        persistLessonProgress(
            forLesson: completedLesson,
            atStepIndex: finalStepIndex,
            lastTimestampSeconds: finalStepEndTimestamp
        )
    }

    /// Persists the current playback timestamp at most once every
    /// `lessonProgressPersistThrottleSeconds`. Prevents spamming SQLite
    /// with a write for every 250ms tick.
    private func persistCurrentLessonTimestampIfThrottled(
        lesson: Lesson,
        stepIndex: Int,
        timestampSeconds: Double
    ) {
        let currentTime = Date()
        if let lastPersistTime = lastLessonProgressPersistTime,
           currentTime.timeIntervalSince(lastPersistTime) < Self.lessonProgressPersistThrottleSeconds {
            return
        }
        lastLessonProgressPersistTime = currentTime
        persistLessonProgress(
            forLesson: lesson,
            atStepIndex: stepIndex,
            lastTimestampSeconds: timestampSeconds
        )
    }
}
