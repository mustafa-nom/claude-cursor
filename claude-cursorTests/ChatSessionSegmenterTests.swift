//
//  ChatSessionSegmenterTests.swift
//  claude-cursorTests
//
//  Exercises the pure splitting + sandwich-merge logic in
//  `ChatSessionSegmenter.splitTurnsIntoSegments`. Boundary cases matter
//  most here — start-edge singletons, end-edge singletons, and the
//  3-minute gap threshold that decides whether a singleton gets absorbed.
//

import Foundation
import Testing
@testable import claude_cursor

// MARK: - Test Helpers

/// Shorthand factory for `ParsedSessionTurn` so test bodies stay focused
/// on the interesting fields (bundleID, browser tool, timestamp).
private func parsedTurn(
    atOffsetSeconds offsetSeconds: TimeInterval,
    appName: String,
    bundleID: String,
    browserTool: String? = nil,
    browserHostname: String? = nil,
    userText: String = "user msg",
    assistantText: String = "assistant msg",
    turnIndex: Int = 0
) -> ParsedSessionTurn {
    // All tests pivot around a synthetic reference date — individual
    // turns offset from it so relative gaps stay readable in the test
    // bodies. The absolute date value doesn't matter.
    let referenceDate = Date(timeIntervalSince1970: 1_800_000_000)
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime]
    let timestampISO = iso.string(
        from: referenceDate.addingTimeInterval(offsetSeconds)
    )
    return ParsedSessionTurn(
        timestampISO8601: timestampISO,
        userUtterance: userText,
        assistantResponse: assistantText,
        frontmostAppName: appName,
        frontmostBundleIdentifier: bundleID,
        browserHostname: browserHostname,
        browserToolName: browserTool,
        outputModeUsed: "chat",
        turnIndexInSessionFile: turnIndex
    )
}

// MARK: - Tests

struct ChatSessionSegmenterSplittingTests {

    /// All turns share the same bundle ID — result should be a single
    /// segment with every turn in order.
    @Test func allSameBundleProducesSingleSegment() async throws {
        let turns: [ParsedSessionTurn] = (0..<5).map { index in
            parsedTurn(
                atOffsetSeconds: Double(index) * 30,
                appName: "VS Code",
                bundleID: "com.microsoft.VSCode",
                turnIndex: index
            )
        }

        let segments = ChatSessionSegmenter.splitTurnsIntoSegments(
            parsedTurns: turns,
            sandwichMergeMaxGapSeconds: 180
        )

        #expect(segments.count == 1)
        #expect(segments.first?.bundleIdentifier == "com.microsoft.VSCode")
        #expect(segments.first?.turnsInOrder.count == 5)
    }

    /// Two app contexts → two segments.
    @Test func twoBundlesProduceTwoSegments() async throws {
        let turns: [ParsedSessionTurn] = [
            parsedTurn(atOffsetSeconds: 0,   appName: "VS Code", bundleID: "com.microsoft.VSCode", turnIndex: 0),
            parsedTurn(atOffsetSeconds: 30,  appName: "VS Code", bundleID: "com.microsoft.VSCode", turnIndex: 1),
            parsedTurn(atOffsetSeconds: 60,  appName: "Figma",   bundleID: "com.figma.Desktop",    turnIndex: 2),
            parsedTurn(atOffsetSeconds: 90,  appName: "Figma",   bundleID: "com.figma.Desktop",    turnIndex: 3)
        ]

        let segments = ChatSessionSegmenter.splitTurnsIntoSegments(
            parsedTurns: turns,
            sandwichMergeMaxGapSeconds: 180
        )

        #expect(segments.count == 2)
        #expect(segments[0].bundleIdentifier == "com.microsoft.VSCode")
        #expect(segments[0].turnsInOrder.count == 2)
        #expect(segments[1].bundleIdentifier == "com.figma.Desktop")
        #expect(segments[1].turnsInOrder.count == 2)
    }

    /// Legacy session files have no bundleID column — every turn arrives
    /// with `frontmostBundleIdentifier = ""`. They should all group
    /// together under the app name rather than splitting on every turn.
    @Test func emptyBundleIDsStayAsSingleSegment() async throws {
        let turns: [ParsedSessionTurn] = (0..<4).map { index in
            parsedTurn(
                atOffsetSeconds: Double(index) * 20,
                appName: "Legacy App",
                bundleID: "",
                turnIndex: index
            )
        }

        let segments = ChatSessionSegmenter.splitTurnsIntoSegments(
            parsedTurns: turns,
            sandwichMergeMaxGapSeconds: 180
        )

        #expect(segments.count == 1)
        #expect(segments.first?.bundleIdentifier == "")
        #expect(segments.first?.turnsInOrder.count == 4)
    }

    /// Browser tool switch (Linear → Figma) within the same Chrome
    /// bundle should still split into two segments.
    @Test func sameBundleDifferentBrowserToolSplits() async throws {
        let turns: [ParsedSessionTurn] = [
            parsedTurn(atOffsetSeconds: 0,  appName: "Chrome", bundleID: "com.google.Chrome",
                       browserTool: "Linear", browserHostname: "linear.app", turnIndex: 0),
            parsedTurn(atOffsetSeconds: 30, appName: "Chrome", bundleID: "com.google.Chrome",
                       browserTool: "Linear", browserHostname: "linear.app", turnIndex: 1),
            parsedTurn(atOffsetSeconds: 60, appName: "Chrome", bundleID: "com.google.Chrome",
                       browserTool: "Figma", browserHostname: "figma.com", turnIndex: 2)
        ]

        let segments = ChatSessionSegmenter.splitTurnsIntoSegments(
            parsedTurns: turns,
            sandwichMergeMaxGapSeconds: 180
        )

        #expect(segments.count == 2)
        #expect(segments[0].browserToolName == "Linear")
        #expect(segments[1].browserToolName == "Figma")
    }

    // MARK: - Sandwich merge

    /// Classic sandwich: A → B (1 turn) → A with a tight gap. The B
    /// singleton should be absorbed so the tree stays clean.
    @Test func sandwichWithTightGapAbsorbsSingleton() async throws {
        let turns: [ParsedSessionTurn] = [
            parsedTurn(atOffsetSeconds: 0,   bundleID: "com.microsoft.VSCode", appName: "VS Code", turnIndex: 0),
            parsedTurn(atOffsetSeconds: 30,  bundleID: "com.microsoft.VSCode", appName: "VS Code", turnIndex: 1),
            parsedTurn(atOffsetSeconds: 60,  bundleID: "com.tinyspeck.slackmacgap", appName: "Slack", turnIndex: 2),
            parsedTurn(atOffsetSeconds: 90,  bundleID: "com.microsoft.VSCode", appName: "VS Code", turnIndex: 3),
            parsedTurn(atOffsetSeconds: 120, bundleID: "com.microsoft.VSCode", appName: "VS Code", turnIndex: 4)
        ]

        let segments = ChatSessionSegmenter.splitTurnsIntoSegments(
            parsedTurns: turns,
            sandwichMergeMaxGapSeconds: 180
        )

        // Expect one merged VS Code segment containing all 5 turns.
        #expect(segments.count == 1)
        #expect(segments.first?.bundleIdentifier == "com.microsoft.VSCode")
        #expect(segments.first?.turnsInOrder.count == 5)
    }

    /// Same sandwich shape, but the gap between the flanking groups is
    /// longer than the merge window. The singleton should stand as its
    /// own segment.
    @Test func sandwichWithWideGapKeepsSingleton() async throws {
        let turns: [ParsedSessionTurn] = [
            parsedTurn(atOffsetSeconds: 0,   bundleID: "com.microsoft.VSCode", appName: "VS Code", turnIndex: 0),
            parsedTurn(atOffsetSeconds: 30,  bundleID: "com.microsoft.VSCode", appName: "VS Code", turnIndex: 1),
            parsedTurn(atOffsetSeconds: 60,  bundleID: "com.tinyspeck.slackmacgap", appName: "Slack", turnIndex: 2),
            // 5 minutes later → sandwich window (3 min) is exceeded.
            parsedTurn(atOffsetSeconds: 360, bundleID: "com.microsoft.VSCode", appName: "VS Code", turnIndex: 3),
            parsedTurn(atOffsetSeconds: 390, bundleID: "com.microsoft.VSCode", appName: "VS Code", turnIndex: 4)
        ]

        let segments = ChatSessionSegmenter.splitTurnsIntoSegments(
            parsedTurns: turns,
            sandwichMergeMaxGapSeconds: 180
        )

        #expect(segments.count == 3)
        #expect(segments[0].bundleIdentifier == "com.microsoft.VSCode")
        #expect(segments[1].bundleIdentifier == "com.tinyspeck.slackmacgap")
        #expect(segments[1].turnsInOrder.count == 1)
        #expect(segments[2].bundleIdentifier == "com.microsoft.VSCode")
    }

    /// Singleton at the very start of a session has no left neighbor —
    /// there's no sandwich to check, so it stays as its own segment.
    @Test func startEdgeSingletonIsKept() async throws {
        let turns: [ParsedSessionTurn] = [
            parsedTurn(atOffsetSeconds: 0,   bundleID: "com.tinyspeck.slackmacgap", appName: "Slack", turnIndex: 0),
            parsedTurn(atOffsetSeconds: 30,  bundleID: "com.microsoft.VSCode", appName: "VS Code", turnIndex: 1),
            parsedTurn(atOffsetSeconds: 60,  bundleID: "com.microsoft.VSCode", appName: "VS Code", turnIndex: 2),
            parsedTurn(atOffsetSeconds: 90,  bundleID: "com.microsoft.VSCode", appName: "VS Code", turnIndex: 3)
        ]

        let segments = ChatSessionSegmenter.splitTurnsIntoSegments(
            parsedTurns: turns,
            sandwichMergeMaxGapSeconds: 180
        )

        #expect(segments.count == 2)
        #expect(segments[0].bundleIdentifier == "com.tinyspeck.slackmacgap")
        #expect(segments[0].turnsInOrder.count == 1)
        #expect(segments[1].bundleIdentifier == "com.microsoft.VSCode")
    }

    /// Symmetric case: singleton at the end with no right neighbor stays.
    @Test func endEdgeSingletonIsKept() async throws {
        let turns: [ParsedSessionTurn] = [
            parsedTurn(atOffsetSeconds: 0,   bundleID: "com.microsoft.VSCode", appName: "VS Code", turnIndex: 0),
            parsedTurn(atOffsetSeconds: 30,  bundleID: "com.microsoft.VSCode", appName: "VS Code", turnIndex: 1),
            parsedTurn(atOffsetSeconds: 60,  bundleID: "com.microsoft.VSCode", appName: "VS Code", turnIndex: 2),
            parsedTurn(atOffsetSeconds: 90,  bundleID: "com.tinyspeck.slackmacgap", appName: "Slack", turnIndex: 3)
        ]

        let segments = ChatSessionSegmenter.splitTurnsIntoSegments(
            parsedTurns: turns,
            sandwichMergeMaxGapSeconds: 180
        )

        #expect(segments.count == 2)
        #expect(segments[0].bundleIdentifier == "com.microsoft.VSCode")
        #expect(segments[1].bundleIdentifier == "com.tinyspeck.slackmacgap")
        #expect(segments[1].turnsInOrder.count == 1)
    }

    /// Two adjacent singletons with DIFFERENT bundles in the middle of a
    /// long VS Code session. Neither flanking neighbor for the inner pair
    /// shares identity, so neither gets absorbed — we should see 4
    /// segments total: VSCode, Slack, Figma, VSCode.
    @Test func twoAdjacentSingletonsStayAsOwnSegments() async throws {
        let turns: [ParsedSessionTurn] = [
            parsedTurn(atOffsetSeconds: 0,   bundleID: "com.microsoft.VSCode", appName: "VS Code", turnIndex: 0),
            parsedTurn(atOffsetSeconds: 30,  bundleID: "com.microsoft.VSCode", appName: "VS Code", turnIndex: 1),
            parsedTurn(atOffsetSeconds: 60,  bundleID: "com.tinyspeck.slackmacgap", appName: "Slack", turnIndex: 2),
            parsedTurn(atOffsetSeconds: 90,  bundleID: "com.figma.Desktop", appName: "Figma", turnIndex: 3),
            parsedTurn(atOffsetSeconds: 120, bundleID: "com.microsoft.VSCode", appName: "VS Code", turnIndex: 4)
        ]

        let segments = ChatSessionSegmenter.splitTurnsIntoSegments(
            parsedTurns: turns,
            sandwichMergeMaxGapSeconds: 180
        )

        #expect(segments.count == 4)
        #expect(segments[0].bundleIdentifier == "com.microsoft.VSCode")
        #expect(segments[1].bundleIdentifier == "com.tinyspeck.slackmacgap")
        #expect(segments[2].bundleIdentifier == "com.figma.Desktop")
        #expect(segments[3].bundleIdentifier == "com.microsoft.VSCode")
    }

    /// Fifty-turn single-bundle session should never split. Acts as a
    /// smoke test that the in-memory observer cap (50) wouldn't break
    /// long sessions when the segmenter replays from disk.
    @Test func longSingleBundleSessionProducesOneSegment() async throws {
        let turns: [ParsedSessionTurn] = (0..<50).map { index in
            parsedTurn(
                atOffsetSeconds: Double(index) * 10,
                appName: "VS Code",
                bundleID: "com.microsoft.VSCode",
                turnIndex: index
            )
        }

        let segments = ChatSessionSegmenter.splitTurnsIntoSegments(
            parsedTurns: turns,
            sandwichMergeMaxGapSeconds: 180
        )

        #expect(segments.count == 1)
        #expect(segments.first?.turnsInOrder.count == 50)
    }

    /// Empty input → empty output. Makes sure the algorithm handles the
    /// no-turns-yet case cleanly.
    @Test func emptyTurnsProducesNoSegments() async throws {
        let segments = ChatSessionSegmenter.splitTurnsIntoSegments(
            parsedTurns: [],
            sandwichMergeMaxGapSeconds: 180
        )
        #expect(segments.isEmpty)
    }
}
