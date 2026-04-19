//
//  OneShotAutomationSmokeTest.swift
//  claude-cursorUITests
//
//  CI smoke test for the demoted one-shot CGEvent automation path.
//
//  Why this exists:
//    After Phase 3 flipped Claude Computer Use to be the default automation
//    backend, the one-shot path became an escape hatch — reachable only via
//    the hidden "Force one-shot automation (debug)" toggle in the menu-bar
//    panel. Without exercise, that path rots silently and is dead the day
//    the Computer Use beta needs a rollback. This test keeps it exercised.
//
//  Gating:
//    - XCTSkipUnless checks `CI_SMOKE_TESTS_ENABLED=1` so local runs of the
//      full XCUITest suite don't accidentally fire off automation against
//      the developer's Chrome.
//    - The app-side hooks in `CompanionManager.applySmokeTestEnvironmentHooksIfNeeded`
//      only activate when `CLAUDE_CURSOR_SMOKE_TEST_ENABLED=1` is set, so
//      even if someone copy-pastes the other env vars into their shell,
//      nothing happens.
//
//  Setup on the CI runner:
//    - Google Chrome installed at /Applications/Google Chrome.app.
//    - Accessibility permission granted to the test-host binary
//      (System Settings → Privacy & Security → Accessibility).
//
//  Flow:
//    1. Launch Chrome in a known state (single window, blank tab).
//    2. Launch claude-cursor with the smoke-test env vars set so it
//       (a) forces one-shot automation and (b) schedules the test
//       utterance via the internal text-message pipeline.
//    3. Wait for the automation to complete (Chrome's address bar should
//       contain the target URL once the one-shot CGEvent sequence runs).
//    4. Assert that Chrome's address bar reflects the expected state.
//

import XCTest

final class OneShotAutomationSmokeTest: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func test_oneShotAutomation_opensGoogleDotComInChrome() throws {
        // Skip unless CI has explicitly opted in. Prevents accidental
        // firings when developers run the whole XCUITest suite locally.
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["CI_SMOKE_TESTS_ENABLED"] == "1",
            "CI_SMOKE_TESTS_ENABLED is not set; skipping one-shot automation smoke test."
        )

        launchChromeAndWaitForReadyWindow()

        let app = XCUIApplication()
        app.launchEnvironment = [
            "CLAUDE_CURSOR_SMOKE_TEST_ENABLED": "1",
            "CLAUDE_CURSOR_FORCE_ONE_SHOT_AUTOMATION": "1",
            "CLAUDE_CURSOR_SMOKE_TEST_UTTERANCE": "open google.com in Chrome",
        ]
        app.launch()

        // The utterance is dispatched 3s after `start()` to let permissions
        // and the overlay settle. Transcript → Claude → one-shot CGEvent
        // → Chrome address bar typically settles in 10–20s, so wait 60s
        // before we give up — plenty of slack for a slow CI runner.
        let chrome = XCUIApplication(bundleIdentifier: "com.google.Chrome")
        let chromeAddressBar = chrome.windows.firstMatch.textFields["Address and search bar"]

        let addressBarResolvedToExpectedURL = NSPredicate(
            format: "value BEGINSWITH[c] 'https://www.google.com' OR value BEGINSWITH[c] 'google.com'"
        )
        let expectation = XCTNSPredicateExpectation(
            predicate: addressBarResolvedToExpectedURL,
            object: chromeAddressBar
        )

        let result = XCTWaiter().wait(for: [expectation], timeout: 60.0)
        XCTAssertEqual(
            result,
            .completed,
            "One-shot automation did not navigate Chrome's address bar to google.com within 60s."
        )
    }

    /// Brings Google Chrome to the front with a blank tab so the automation
    /// has a deterministic target. Closes any existing Chrome windows first
    /// so a leftover page from a prior test run doesn't satisfy the
    /// assertion by accident.
    @MainActor
    private func launchChromeAndWaitForReadyWindow() {
        let chrome = XCUIApplication(bundleIdentifier: "com.google.Chrome")
        chrome.launch()

        let firstWindowAppeared = chrome.windows.firstMatch.waitForExistence(timeout: 15.0)
        XCTAssertTrue(firstWindowAppeared, "Chrome did not open a window within 15s.")

        chrome.activate()
    }
}
