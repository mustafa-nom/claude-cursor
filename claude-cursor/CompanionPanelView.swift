//
//  CompanionPanelView.swift
//  claude-cursor
//
//  The SwiftUI content hosted inside the menu bar panel. Shows the companion
//  voice status, push-to-talk shortcut, and quick settings. Uses always-light
//  paper tokens (`DS.CompanionPanel`) for a calm, Claude-adjacent surface.
//

import AVFoundation
import SwiftUI

private struct ResearchAccordionContentHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct CompanionPanelView: View {
    @ObservedObject var companionManager: CompanionManager

    /// Text the user typed into the "Research a topic" field. Cleared when
    /// the research run finishes successfully; replaced with an inline error
    /// string prefixed with "⚠️" on failure so the user sees what broke
    /// without the panel growing a modal.
    @State private var researchTopicInputText: String = ""

    /// True while `AutoResearchPipeline.ingestTopic` and the follow-up
    /// `ResearchSourceCompressor` call are running. Disables the TextField
    /// and Button, and flips the button content to a spinner.
    @State private var isResearchInProgress: Bool = false

    /// True while the user is holding the Option (⌥) key. Drives the
    /// reveal of the hidden debug submenu (currently the "Force one-shot
    /// automation (debug)" row). The state is updated by the
    /// `flagsChanged` local NSEvent monitor installed in `.onAppear`.
    @State private var isOptionKeyHeld: Bool = false

    /// Retained reference to the NSEvent monitor so we can remove it in
    /// `.onDisappear`. Stored as `Any?` because `addLocalMonitorForEvents`
    /// returns `Any?` — matching the Cocoa API.
    @State private var optionKeyEventMonitor: Any? = nil

    /// Last non-zero height of the research block (collapsed layout reports 0; keep stale for smooth open).
    @State private var researchAccordionMeasuredHeight: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            panelHeader
            Divider()
                .background(DS.CompanionPanel.borderSubtle)
                .padding(.horizontal, 16)

            permissionsCopySection
                .padding(.top, 16)
                .padding(.horizontal, 16)

            if companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted {
                Spacer()
                    .frame(height: 12)

                modelPickerRow
                    .padding(.horizontal, 16)
            }

            if !companionManager.allPermissionsGranted {
                Spacer()
                    .frame(height: 16)

                settingsSection
                    .padding(.horizontal, 16)
            }

            if !companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted {
                Spacer()
                    .frame(height: 16)

                startButton
                    .padding(.horizontal, 16)
            }

            // Show ClaudeCursor toggle — hidden for now
            // if companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted {
            //     Spacer()
            //         .frame(height: 16)
            //
            //     showClaudeCursorToggleRow
            //         .padding(.horizontal, 16)
            // }

            if companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted {
                Spacer()
                    .frame(height: 16)

                tutorModeToggleRow
                    .padding(.horizontal, 16)

                wikiKnowledgeAndResearchSection
                    .padding(.horizontal, 16)

                showChatToggleRow
                    .padding(.horizontal, 16)

                autoCopyResponseToggleRow
                    .padding(.horizontal, 16)

                automationExperimentalToggleRow
                    .padding(.horizontal, 16)

                // Hidden debug submenu — only visible while Option (⌥) is
                // held. Houses escape hatches that normal users should never
                // encounter (e.g. forcing the demoted one-shot CGEvent path
                // when the Claude Computer Use beta is having a bad day).
                if isOptionKeyHeld {
                    forceOneShotAutomationDebugRow
                        .padding(.horizontal, 16)
                        .transition(.opacity)
                }

                followAlongTutorialRow
                    .padding(.horizontal, 16)
            }

            Spacer()
                .frame(height: 12)

            Divider()
                .background(DS.CompanionPanel.borderSubtle)
                .padding(.horizontal, 16)

            footerSection
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
        }
        .frame(width: 320)
        .background(panelBackground)
        .onAppear {
            installOptionKeyEventMonitorIfNeeded()
        }
        .onDisappear {
            removeOptionKeyEventMonitorIfInstalled()
        }
    }

    /// Installs a local `flagsChanged` monitor so the hidden debug submenu
    /// can appear while the user holds Option (⌥). Installed in
    /// `.onAppear` and paired with `removeOptionKeyEventMonitorIfInstalled`
    /// in `.onDisappear` so we don't leak the monitor across panel opens.
    private func installOptionKeyEventMonitorIfNeeded() {
        guard optionKeyEventMonitor == nil else { return }
        isOptionKeyHeld = NSEvent.modifierFlags.contains(.option)
        optionKeyEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: .flagsChanged
        ) { flagsChangedEvent in
            let isOptionNowHeld = flagsChangedEvent.modifierFlags.contains(.option)
            // Keeping this on the main thread because SwiftUI `@State`
            // mutations must happen there.
            DispatchQueue.main.async {
                withAnimation(.easeOut(duration: 0.12)) {
                    isOptionKeyHeld = isOptionNowHeld
                }
            }
            return flagsChangedEvent
        }
    }

    private func removeOptionKeyEventMonitorIfInstalled() {
        if let installedMonitor = optionKeyEventMonitor {
            NSEvent.removeMonitor(installedMonitor)
            optionKeyEventMonitor = nil
        }
        isOptionKeyHeld = false
    }

    // MARK: - Header

    private var panelHeader: some View {
        HStack(alignment: .center) {
            HStack(alignment: .center, spacing: 8) {
                Image("claudeCursor")
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: 12, height: 12)
                    .rotationEffect(.degrees(45))
                    .frame(width: 20, height: 20)
                    .offset(y: -0.75)
                    .accessibilityHidden(true)

                Text("Claude Cursor")
                    .font(.system(size: 14, weight: .semibold, design: .serif))
                    .foregroundColor(DS.CompanionPanel.textPrimary)
            }

            Spacer()

            Button(action: {
                NotificationCenter.default.post(name: .claudeCursorDismissPanel, object: nil)
            }) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(DS.CompanionPanel.textTertiary)
                    .frame(width: 20, height: 20)
                    .background(
                        Circle()
                            .fill(DS.CompanionPanel.closeButtonBackground)
                    )
            }
            .buttonStyle(.plain)
            .pointerCursor()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    // MARK: - Permissions Copy

    @ViewBuilder
    private var permissionsCopySection: some View {
        if companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted {
            Text("Hold Control+Option to talk.")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.CompanionPanel.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if companionManager.allPermissionsGranted {
            Text("You're all set. Hit Start to meet Claude Cursor.")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.CompanionPanel.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if companionManager.hasCompletedOnboarding {
            // Permissions were revoked after onboarding — tell user to re-grant
            VStack(alignment: .leading, spacing: 6) {
                Text("Permissions needed")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(DS.CompanionPanel.textSecondary)

                Text("Some permissions were revoked. Grant all four below to keep using Claude Cursor.")
                    .font(.system(size: 11))
                    .foregroundColor(DS.CompanionPanel.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("Hi, I'm Farza. This is Claude Cursor.")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(DS.CompanionPanel.textSecondary)

                Text("A side project I made for fun to help me learn stuff as I use my computer.")
                    .font(.system(size: 11))
                    .foregroundColor(DS.CompanionPanel.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Nothing runs in the background. Claude Cursor will only take a screenshot when you press the hot key. So, you can give that permission in peace. If you are still sus, eh, I can't do much there champ.")
                    .font(.system(size: 11))
                    .foregroundColor(DS.CompanionPanel.destructiveText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Start Button

    @ViewBuilder
    private var startButton: some View {
        if !companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted {
            Button(action: {
                companionManager.triggerOnboarding()
            }) {
                Text("Start")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(DS.CompanionPanel.textOnAccent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                            .fill(DS.CompanionPanel.accent)
                    )
            }
            .buttonStyle(.plain)
            .pointerCursor()
        }
    }

    // MARK: - Permissions

    private var settingsSection: some View {
        VStack(spacing: 2) {
            Text("PERMISSIONS")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundColor(DS.CompanionPanel.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 6)

            microphonePermissionRow

            accessibilityPermissionRow

            screenRecordingPermissionRow

            if companionManager.hasScreenRecordingPermission {
                screenContentPermissionRow
            }

        }
    }

    private var accessibilityPermissionRow: some View {
        let isGranted = companionManager.hasAccessibilityPermission
        return HStack(alignment: .center) {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: "hand.raised")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isGranted ? DS.CompanionPanel.textTertiary : DS.CompanionPanel.warning)
                    .frame(width: 16)

                Text("Accessibility")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.CompanionPanel.textSecondary)
            }

            Spacer()

            if isGranted {
                HStack(alignment: .center, spacing: 4) {
                    Circle()
                        .fill(DS.CompanionPanel.success)
                        .frame(width: 6, height: 6)
                    Text("Granted")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.CompanionPanel.success)
                }
            } else {
                HStack(spacing: 6) {
                    Button(action: {
                        // Triggers the system accessibility prompt (AXIsProcessTrustedWithOptions)
                        // on first attempt, then opens System Settings on subsequent attempts.
                        WindowPositionManager.requestAccessibilityPermission()
                    }) {
                        Text("Grant")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(DS.CompanionPanel.textOnAccent)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(
                                Capsule()
                                    .fill(DS.CompanionPanel.accent)
                            )
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()

                    Button(action: {
                        // Reveals the app in Finder so the user can drag it into
                        // the Accessibility list if it doesn't appear automatically
                        // (common with unsigned dev builds).
                        WindowPositionManager.revealAppInFinder()
                        WindowPositionManager.openAccessibilitySettings()
                    }) {
                        Text("Find App")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(DS.CompanionPanel.textSecondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(
                                Capsule()
                                    .stroke(DS.CompanionPanel.borderSubtle, lineWidth: 0.8)
                            )
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                }
            }
        }
        .padding(.vertical, 6)
    }

    private var screenRecordingPermissionRow: some View {
        let isGranted = companionManager.hasScreenRecordingPermission
        return HStack(alignment: .center) {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: "rectangle.dashed.badge.record")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isGranted ? DS.CompanionPanel.textTertiary : DS.CompanionPanel.warning)
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Screen Recording")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(DS.CompanionPanel.textSecondary)

                    Text(isGranted
                         ? "Only takes a screenshot when you use the hotkey"
                         : "Quit and reopen after granting")
                        .font(.system(size: 10))
                        .foregroundColor(DS.CompanionPanel.textTertiary)
                }
            }

            Spacer()

            if isGranted {
                HStack(alignment: .center, spacing: 4) {
                    Circle()
                        .fill(DS.CompanionPanel.success)
                        .frame(width: 6, height: 6)
                    Text("Granted")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.CompanionPanel.success)
                }
            } else {
                Button(action: {
                    // Triggers the native macOS screen recording prompt on first
                    // attempt (auto-adds app to the list), then opens System Settings
                    // on subsequent attempts.
                    WindowPositionManager.requestScreenRecordingPermission()
                }) {
                    Text("Grant")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.CompanionPanel.textOnAccent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(DS.CompanionPanel.accent)
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
        .padding(.vertical, 6)
    }

    private var screenContentPermissionRow: some View {
        let isGranted = companionManager.hasScreenContentPermission
        return HStack(alignment: .center) {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: "eye")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isGranted ? DS.CompanionPanel.textTertiary : DS.CompanionPanel.warning)
                    .frame(width: 16)

                Text("Screen Content")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.CompanionPanel.textSecondary)
            }

            Spacer()

            if isGranted {
                HStack(alignment: .center, spacing: 4) {
                    Circle()
                        .fill(DS.CompanionPanel.success)
                        .frame(width: 6, height: 6)
                    Text("Granted")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.CompanionPanel.success)
                }
            } else {
                Button(action: {
                    companionManager.requestScreenContentPermission()
                }) {
                    Text("Grant")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.CompanionPanel.textOnAccent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(DS.CompanionPanel.accent)
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
        .padding(.vertical, 6)
    }

    private var microphonePermissionRow: some View {
        let isGranted = companionManager.hasMicrophonePermission
        return HStack(alignment: .center) {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: "mic")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isGranted ? DS.CompanionPanel.textTertiary : DS.CompanionPanel.warning)
                    .frame(width: 16)

                Text("Microphone")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.CompanionPanel.textSecondary)
            }

            Spacer()

            if isGranted {
                HStack(alignment: .center, spacing: 4) {
                    Circle()
                        .fill(DS.CompanionPanel.success)
                        .frame(width: 6, height: 6)
                    Text("Granted")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.CompanionPanel.success)
                }
            } else {
                Button(action: {
                    // Triggers the native macOS microphone permission dialog on
                    // first attempt. If already denied, opens System Settings.
                    let status = AVCaptureDevice.authorizationStatus(for: .audio)
                    if status == .notDetermined {
                        AVCaptureDevice.requestAccess(for: .audio) { _ in }
                    } else {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }) {
                    Text("Grant")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.CompanionPanel.textOnAccent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(DS.CompanionPanel.accent)
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
        .padding(.vertical, 6)
    }

    private func permissionRow(
        label: String,
        iconName: String,
        isGranted: Bool,
        settingsURL: String
    ) -> some View {
        HStack(alignment: .center) {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: iconName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isGranted ? DS.CompanionPanel.textTertiary : DS.CompanionPanel.warning)
                    .frame(width: 16)

                Text(label)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.CompanionPanel.textSecondary)
            }

            Spacer()

            if isGranted {
                HStack(alignment: .center, spacing: 4) {
                    Circle()
                        .fill(DS.CompanionPanel.success)
                        .frame(width: 6, height: 6)
                    Text("Granted")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.CompanionPanel.success)
                }
            } else {
                Button(action: {
                    if let url = URL(string: settingsURL) {
                        NSWorkspace.shared.open(url)
                    }
                }) {
                    Text("Grant")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.CompanionPanel.textOnAccent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(DS.CompanionPanel.accent)
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
        .padding(.vertical, 6)
    }



    // MARK: - Auto-Copy Response Toggle

    private var autoCopyResponseToggleRow: some View {
        HStack(alignment: .center) {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: "doc.on.clipboard")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.CompanionPanel.textTertiary)
                    .frame(width: 16)

                Text("Copy responses")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.CompanionPanel.textSecondary)
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { companionManager.isAutoCopyResponseEnabled },
                set: { newValue in
                    CompanionPanelSoundFeedback.shared.playEnterSound()
                    companionManager.setAutoCopyResponseEnabled(newValue)
                }
            ))
            .toggleStyle(CompanionPanelSwitchToggleStyle())
            .labelsHidden()
        }
        .padding(.vertical, 4)
    }

    // MARK: - Show ClaudeCursor Cursor Toggle

    private var showClaudeCursorToggleRow: some View {
        HStack(alignment: .center) {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: "cursorarrow")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.CompanionPanel.textTertiary)
                    .frame(width: 16)

                Text("Show Claude Cursor")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.CompanionPanel.textSecondary)
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { companionManager.isClaudeCursorEnabled },
                set: { newValue in
                    CompanionPanelSoundFeedback.shared.playEnterSound()
                    companionManager.setClaudeCursorEnabled(newValue)
                }
            ))
            .toggleStyle(CompanionPanelSwitchToggleStyle())
            .labelsHidden()
        }
        .padding(.vertical, 4)
    }

    private var tutorModeToggleRow: some View {
        HStack(alignment: .center) {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: "graduationcap")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.CompanionPanel.textTertiary)
                    .frame(width: 16)

                Text("Tutor mode")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.CompanionPanel.textSecondary)
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { companionManager.isTutorModeEnabled },
                set: { newValue in
                    CompanionPanelSoundFeedback.shared.playEnterSound()
                    companionManager.setTutorModeEnabled(newValue)
                }
            ))
            .toggleStyle(CompanionPanelSwitchToggleStyle())
            .labelsHidden()
        }
        .padding(.vertical, 4)
    }

    // MARK: - Wiki Knowledge Toggle

    private var wikiKnowledgeToggleRow: some View {
        HStack(alignment: .center) {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: "book.closed")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.CompanionPanel.textTertiary)
                    .frame(width: 16)

                Text("Wiki knowledge")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.CompanionPanel.textSecondary)
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { companionManager.isWikiKnowledgeEnabled },
                set: { newWikiKnowledgeEnabledValue in
                    withAnimation(
                        .timingCurve(0.25, 0.1, 0.25, 1, duration: 0.22)
                    ) {
                        CompanionPanelSoundFeedback.shared.playEnterSound()
                        companionManager.setWikiKnowledgeEnabled(newWikiKnowledgeEnabledValue)
                    }
                }
            ))
            .toggleStyle(CompanionPanelSwitchToggleStyle())
            .labelsHidden()
        }
        .padding(.vertical, 4)
    }

    /// Wiki toggle plus research strip: height-driven expand/collapse (shadcn-style accordion).
    private var wikiKnowledgeAndResearchSection: some View {
        let isWikiResearchAccordionExpanded = companionManager.isWikiKnowledgeEnabled
        let wikiResearchAccordionCurve = Animation.timingCurve(0.25, 0.1, 0.25, 1, duration: 0.22)
        let resolvedResearchAccordionHeight: CGFloat = {
            if !isWikiResearchAccordionExpanded { return 0 }
            if researchAccordionMeasuredHeight > 0.5 {
                return researchAccordionMeasuredHeight
            }
            return 88
        }()

        return VStack(alignment: .leading, spacing: 0) {
            wikiKnowledgeToggleRow
            researchTopicRowContent
                .background(
                    GeometryReader { geometry in
                        Color.clear.preference(
                            key: ResearchAccordionContentHeightPreferenceKey.self,
                            value: geometry.size.height
                        )
                    }
                )
                .frame(height: resolvedResearchAccordionHeight, alignment: .top)
                .clipped()
                .opacity(isWikiResearchAccordionExpanded ? 1 : 0)
                .allowsHitTesting(isWikiResearchAccordionExpanded)
        }
        .animation(wikiResearchAccordionCurve, value: isWikiResearchAccordionExpanded)
        .animation(wikiResearchAccordionCurve, value: researchAccordionMeasuredHeight)
        .onPreferenceChange(ResearchAccordionContentHeightPreferenceKey.self) { reportedHeight in
            if reportedHeight > 0.5 {
                researchAccordionMeasuredHeight = reportedHeight
            }
        }
    }

    // MARK: - Research a Topic

    /// Freeform input + button that triggers `AutoResearchPipeline.ingestTopic`
    /// followed by `ResearchSourceCompressor`. Only visible when Wiki
    /// Knowledge is on — symmetric with the `research_topic` tool gate in
    /// `CompanionToolRegistry.availableToolsForCurrentTurn()`, since research
    /// without the wiki has nowhere to land its output.
    private var researchTopicRowContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: "books.vertical")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.CompanionPanel.textTertiary)
                    .frame(width: 16)

                Text("Research a topic")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.CompanionPanel.textSecondary)
            }

            HStack(alignment: .center, spacing: 8) {
                ZStack(alignment: .leading) {
                    if researchTopicInputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("e.g. DaVinci Resolve color grading")
                            .foregroundStyle(DS.CompanionPanel.fieldPlaceholder)
                            .font(.system(size: 12))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .allowsHitTesting(false)
                    }
                    TextField("", text: $researchTopicInputText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundColor(DS.CompanionPanel.textPrimary)
                        .tint(DS.CompanionPanel.accent)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .onSubmit { triggerResearchForCurrentInput() }
                        .disabled(isResearchInProgress)
                }
                .background(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.small)
                        .fill(DS.CompanionPanel.surface1)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.small)
                        .stroke(DS.CompanionPanel.borderSubtle, lineWidth: 1)
                )

                researchStartButton
            }
        }
        .padding(.vertical, 4)
    }

    /// The Research / Loading button for the "Research a topic" row. Loading
    /// state is a thin ProgressView + "Working" label so the user knows the
    /// ingest (up to ~30s for a cold curated run) hasn't silently stalled.
    @ViewBuilder
    private var researchStartButton: some View {
        if isResearchInProgress {
            HStack(alignment: .center, spacing: 4) {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)
                Text("Working")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule().fill(DS.CompanionPanel.accent.opacity(0.7)))
        } else {
            Button(action: triggerResearchForCurrentInput) {
                Text("Research")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(DS.CompanionPanel.accent))
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .disabled(
                researchTopicInputText
                    .trimmingCharacters(in: .whitespaces)
                    .isEmpty
            )
        }
    }

    /// Kicks off the full research pipeline for the topic currently in the
    /// input field. Unlike the `research_topic` tool path (which fires
    /// compression in the background so Claude's reply isn't delayed), the
    /// UI path awaits compression — the user already paid the synchronous
    /// wait cost by clicking the button, so giving them a definitive
    /// "done, now queryable" signal is worth it.
    private func triggerResearchForCurrentInput() {
        let trimmedTopic = researchTopicInputText
            .trimmingCharacters(in: .whitespaces)
        guard !trimmedTopic.isEmpty, !isResearchInProgress else { return }

        // Strip a stale "⚠️ ..." error off the front before starting — if
        // the user is re-running, they've seen the error already.
        let topicToResearch: String
        if trimmedTopic.hasPrefix("⚠️") {
            topicToResearch = ""
        } else {
            topicToResearch = trimmedTopic
        }
        guard !topicToResearch.isEmpty else { return }

        isResearchInProgress = true
        Task {
            do {
                let ingestedSources = try await companionManager
                    .autoResearchPipeline
                    .ingestTopic(topicToResearch)
                await companionManager.researchSourceCompressor
                    .compressResearchSourcesIntoWikiPage(
                        forTopic: topicToResearch,
                        ingestedRawSources: ingestedSources
                    )
                await MainActor.run {
                    researchTopicInputText = ""
                    isResearchInProgress = false
                }
            } catch {
                await MainActor.run {
                    isResearchInProgress = false
                    researchTopicInputText = "⚠️ \(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: - Automation (Experimental) Toggle

    /// Experimental: lets Claude dispatch real clicks + keyboard input during
    /// guided navigation. Defaults off. Every sequence still asks for a
    /// one-time consent before running, and the deny-list blocks sensitive
    /// apps regardless of this flag.
    private var automationExperimentalToggleRow: some View {
        HStack(alignment: .center) {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: "cursorarrow.click")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.CompanionPanel.textTertiary)
                    .frame(width: 16)

                Text("Auto-click (experimental)")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.CompanionPanel.textSecondary)
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { companionManager.isAutomationExperimentalEnabled },
                set: { newValue in
                    CompanionPanelSoundFeedback.shared.playEnterSound()
                    companionManager.setAutomationExperimentalEnabled(newValue)
                }
            ))
            .toggleStyle(CompanionPanelSwitchToggleStyle())
            .labelsHidden()
        }
        .padding(.vertical, 4)
    }

    /// Debug-only escape hatch: forces the demoted one-shot CGEvent path
    /// instead of the Claude Computer Use agent loop (the default). Only
    /// renders while Option (⌥) is held — see `isOptionKeyHeld` and the
    /// `flagsChanged` monitor on the root view. Intended for the case where
    /// the Computer Use beta is having an outage and we need to fall back
    /// to locally-dispatched automation without shipping a new build.
    private var forceOneShotAutomationDebugRow: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "wrench.and.screwdriver")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.CompanionPanel.textTertiary)
                .frame(width: 16)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .center) {
                    Text("Force one-shot automation (debug)")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(DS.CompanionPanel.textSecondary)
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { companionManager.preferOneShotAutomationForDebugging },
                        set: { newValue in
                            CompanionPanelSoundFeedback.shared.playEnterSound()
                            companionManager.setPreferOneShotAutomationForDebugging(newValue)
                        }
                    ))
                    .toggleStyle(CompanionPanelSwitchToggleStyle())
                    .labelsHidden()
                }
                Text("Bypasses the Computer Use agent loop and runs the legacy one-shot CGEvent path instead. Only use when the Computer Use beta is unavailable.")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundColor(DS.CompanionPanel.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Show Chat Toggle

    private var showChatToggleRow: some View {
        HStack(alignment: .center) {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: "text.bubble")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.CompanionPanel.textTertiary)
                    .frame(width: 16)

                Text("Show chat")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.CompanionPanel.textSecondary)
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { companionManager.isShowChatEnabled },
                set: { newValue in
                    CompanionPanelSoundFeedback.shared.playEnterSound()
                    companionManager.setShowChatEnabled(newValue)
                }
            ))
            .toggleStyle(CompanionPanelSwitchToggleStyle())
            .labelsHidden()
        }
        .padding(.vertical, 4)
    }

    // MARK: - Follow-Along Tutorial

    private var followAlongTutorialRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: "play.rectangle")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.CompanionPanel.textTertiary)
                    .frame(width: 16)

                Text("Follow-along tutorial")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.CompanionPanel.textSecondary)
            }

            HStack(alignment: .center, spacing: 8) {
                ZStack(alignment: .leading) {
                    if companionManager.followAlongTutorialURL
                        .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    {
                        Text("Paste YouTube URL")
                            .foregroundStyle(DS.CompanionPanel.fieldPlaceholder)
                            .font(.system(size: 12))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .allowsHitTesting(false)
                    }
                    TextField(
                        "",
                        text: Binding(
                            get: { companionManager.followAlongTutorialURL },
                            set: { newURLValue in
                                companionManager.followAlongTutorialURL = newURLValue
                                if companionManager.lessonLoadErrorMessage != nil {
                                    companionManager.lessonLoadErrorMessage = nil
                                }
                            }
                        )
                    )
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundColor(DS.CompanionPanel.textPrimary)
                    .tint(DS.CompanionPanel.accent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .disabled(companionManager.isLessonLoading)
                }
                .background(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.small)
                        .fill(DS.CompanionPanel.surface1)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.small)
                        .stroke(DS.CompanionPanel.borderSubtle, lineWidth: 1)
                )

                followAlongStartOrStopButton
            }

            if let currentLessonLoadError = companionManager.lessonLoadErrorMessage {
                Text(currentLessonLoadError)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundColor(DS.CompanionPanel.destructiveText)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let currentlyRunningLesson = companionManager.activeLesson {
                Text("In progress: \(currentlyRunningLesson.videoTitle)")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundColor(DS.CompanionPanel.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.vertical, 4)
    }

    /// The Start/Stop/Loading button for follow-along tutorials. Renders
    /// three distinct visual states driven by CompanionManager:
    ///   - Stop: when a lesson is currently active
    ///   - Loading: while extraction is in-flight
    ///   - Start: otherwise (disabled when the URL field is empty)
    @ViewBuilder
    private var followAlongStartOrStopButton: some View {
        if companionManager.activeLesson != nil {
            Button(action: {
                companionManager.stopFollowAlongTutorial()
            }) {
                Text("Stop")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        Capsule().fill(DS.CompanionPanel.destructive)
                    )
            }
            .buttonStyle(.plain)
            .pointerCursor()
        } else if companionManager.isLessonLoading {
            HStack(alignment: .center, spacing: 4) {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)
                Text("Loading")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Capsule().fill(DS.CompanionPanel.accent.opacity(0.7))
            )
        } else {
            Button(action: {
                companionManager.startFollowAlongTutorial()
            }) {
                Text("Start")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        Capsule()
                            .fill(companionManager.followAlongTutorialURL.isEmpty
                                ? DS.CompanionPanel.accent.opacity(0.4)
                                : DS.CompanionPanel.accent)
                    )
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .disabled(companionManager.followAlongTutorialURL.isEmpty)
        }
    }

    private var speechToTextProviderRow: some View {
        HStack(alignment: .center) {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: "mic.badge.waveform")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.CompanionPanel.textTertiary)
                    .frame(width: 16)

                Text("Speech to Text")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.CompanionPanel.textSecondary)
            }

            Spacer()

            Text(companionManager.buddyDictationManager.transcriptionProviderDisplayName)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(DS.CompanionPanel.textTertiary)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Model Picker

    private var modelPickerRow: some View {
        HStack(alignment: .center) {
            Text("Model")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(DS.CompanionPanel.textSecondary)

            Spacer()

            HStack(spacing: 0) {
                modelOptionButton(label: "Sonnet", modelID: "claude-sonnet-4-6")
                modelOptionButton(label: "Opus", modelID: "claude-opus-4-6")
            }
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(DS.CompanionPanel.surface1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(DS.CompanionPanel.borderSubtle, lineWidth: 0.5)
            )
        }
        .padding(.vertical, 4)
    }

    private func modelOptionButton(label: String, modelID: String) -> some View {
        let isSelected = companionManager.selectedModel == modelID
        return Button(action: {
            if companionManager.selectedModel != modelID {
                CompanionPanelSoundFeedback.shared.playEnterSound()
            }
            companionManager.setSelectedModel(modelID)
        }) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(isSelected ? DS.CompanionPanel.textPrimary : DS.CompanionPanel.textTertiary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(isSelected ? DS.CompanionPanel.accentSubtle : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    // MARK: - Footer

    private var footerSection: some View {
        HStack(alignment: .center) {
            Spacer(minLength: 0)
            Button(action: {
                NSApp.terminate(nil)
            }) {
                HStack(alignment: .center, spacing: 6) {
                    Image(systemName: "power")
                        .font(.system(size: 12, weight: .medium))
                    Text("Quit Claude Cursor")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundColor(DS.CompanionPanel.textTertiary)
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            .pointerCursor()
            Spacer(minLength: 0)
        }
        // if companionManager.hasCompletedOnboarding {
        //     Button(action: { companionManager.replayOnboarding() }) {
        //         HStack(spacing: 6) {
        //             Image(systemName: "play.circle")
        //                 .font(.system(size: 11, weight: .medium))
        //             Text("Watch Onboarding Again")
        //                 .font(.system(size: 12, weight: .medium))
        //         }
        //         .foregroundColor(DS.CompanionPanel.textTertiary)
        //     }
        //     .buttonStyle(.plain)
        //     .pointerCursor()
        // }
    }

    // MARK: - Visual Helpers

    private var panelBackground: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(DS.CompanionPanel.background)
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(DS.CompanionPanel.borderSubtle, lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.08), radius: 24, x: 0, y: 10)
            .shadow(color: Color.black.opacity(0.04), radius: 2, x: 0, y: 1)
    }

}

// MARK: - Companion panel switch (visible off-state on paper background)

private struct CompanionPanelSwitchToggleStyle: ToggleStyle {
    private let trackWidth: CGFloat = 40
    private let trackHeight: CGFloat = 22
    private let knobSideLength: CGFloat = 18
    private let knobHorizontalInset: CGFloat = 2

    func makeBody(configuration: Configuration) -> some View {
        let knobLeadingOffsetWhenOn = trackWidth - knobSideLength - knobHorizontalInset

        Button {
            configuration.isOn.toggle()
        } label: {
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(configuration.isOn ? DS.CompanionPanel.accent : DS.CompanionPanel.switchTrackOff)
                    .frame(width: trackWidth, height: trackHeight)
                    .overlay(
                        Capsule()
                            .stroke(
                                configuration.isOn ? Color.clear : DS.CompanionPanel.switchTrackOffBorder,
                                lineWidth: 1
                            )
                    )

                Circle()
                    .fill(Color.white)
                    .frame(width: knobSideLength, height: knobSideLength)
                    .shadow(color: Color.black.opacity(0.15), radius: 2, x: 0, y: 1)
                    .offset(x: configuration.isOn ? knobLeadingOffsetWhenOn : knobHorizontalInset)
                    .animation(.spring(response: 0.22, dampingFraction: 0.85), value: configuration.isOn)
            }
            .frame(width: trackWidth, height: trackHeight, alignment: .leading)
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(configuration.isOn ? Text("On") : Text("Off"))
    }
}
