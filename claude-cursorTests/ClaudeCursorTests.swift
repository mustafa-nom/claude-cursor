//
//  ClaudeCursorTests.swift
//  claude-cursorTests
//
//  Created by thorfinn on 3/2/26.
//

import AppKit
import Testing
@testable import claude_cursor

struct ClaudeCursorTests {

    @Test func firstPermissionRequestUsesSystemPromptOnly() async throws {
        let presentationDestination = WindowPositionManager.permissionRequestPresentationDestination(
            hasPermissionNow: false,
            hasAttemptedSystemPrompt: false
        )

        #expect(presentationDestination == .systemPrompt)
    }

    @Test func repeatedPermissionRequestOpensSystemSettings() async throws {
        let presentationDestination = WindowPositionManager.permissionRequestPresentationDestination(
            hasPermissionNow: false,
            hasAttemptedSystemPrompt: true
        )

        #expect(presentationDestination == .systemSettings)
    }

    @Test func knownGrantedScreenRecordingPermissionSkipsTheGate() async throws {
        let shouldTreatPermissionAsGranted = WindowPositionManager.shouldTreatScreenRecordingPermissionAsGrantedForSessionLaunch(
            hasScreenRecordingPermissionNow: false,
            hasPreviouslyConfirmedScreenRecordingPermission: true
        )

        #expect(shouldTreatPermissionAsGranted)
    }

    @Test func computerUseImageFormattingPicksSixteenTenForStandardMacDisplay() {
        let resolution = ComputerUseImageFormatting.bestComputerUseResolution(
            forDisplayWidth: 1280,
            displayHeight: 800
        )
        #expect(resolution.width == 1280)
        #expect(resolution.height == 800)
    }

    @Test func computerUseTargetDisplayNumberIsPositive() {
        let number = ComputerUseTargetDisplay.displayNumber(for: NSScreen.main!)
        #expect(number >= 1)
    }

    @Test func explainerDedup_stripsCaseInsensitiveWhitespaceFlexiblePrefix() {
        let remainder = ExplainerSpokenTextDedup.remainingAssistantTextAfterOverviewIfRedundant(
            fullAssistantText: "Here is the map. next tap export.",
            explainerOverview: "here is the map."
        )
        #expect(remainder == "next tap export.")
    }

    @Test func explainerDedup_whenFullTextMatchesOverview_yieldsEmpty() {
        let remainder = ExplainerSpokenTextDedup.remainingAssistantTextAfterOverviewIfRedundant(
            fullAssistantText: "Quick tour of the bar.",
            explainerOverview: "Quick tour of the bar."
        )
        #expect(remainder.isEmpty)
    }

    @Test func explainerDedup_whenNoPrefixMatch_returnsFullTrimmed() {
        let remainder = ExplainerSpokenTextDedup.remainingAssistantTextAfterOverviewIfRedundant(
            fullAssistantText: "  done.  ",
            explainerOverview: "something else entirely"
        )
        #expect(remainder == "done.")
    }

}
