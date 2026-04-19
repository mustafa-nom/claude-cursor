//
//  ComputerUseTypeTextNormalizationTests.swift
//  claude-cursorTests
//

import XCTest
@testable import claude_cursor

final class ComputerUseTypeTextNormalizationTests: XCTestCase {

    func test_emptyTrimmed_submitsReturnOnly() {
        let normalized = ComputerUseTypeTextNormalization.normalizedTypeAction(from: "  \n  ")
        XCTAssertEqual(normalized.textToType, "")
        XCTAssertTrue(normalized.shouldPressReturnAfterTyping)
    }

    func test_exactReturn_submitsReturnOnly() {
        let normalized = ComputerUseTypeTextNormalization.normalizedTypeAction(from: "Return")
        XCTAssertEqual(normalized.textToType, "")
        XCTAssertTrue(normalized.shouldPressReturnAfterTyping)
    }

    func test_exactEnter_submitsReturnOnly() {
        let normalized = ComputerUseTypeTextNormalization.normalizedTypeAction(from: "ENTER")
        XCTAssertEqual(normalized.textToType, "")
        XCTAssertTrue(normalized.shouldPressReturnAfterTyping)
    }

    func test_suffixReturnWithoutSpace_typesPrefixAndReturn() {
        let normalized = ComputerUseTypeTextNormalization.normalizedTypeAction(
            from: "https://example.com/cursorreturn"
        )
        XCTAssertEqual(normalized.textToType, "https://example.com/cursor")
        XCTAssertTrue(normalized.shouldPressReturnAfterTyping)
    }

    func test_suffixReturnWithSpace_typesFullStringNoExtraReturn() {
        let normalized = ComputerUseTypeTextNormalization.normalizedTypeAction(from: "how to use return")
        XCTAssertEqual(normalized.textToType, "how to use return")
        XCTAssertFalse(normalized.shouldPressReturnAfterTyping)
    }

    func test_plainText_noReturn() {
        let normalized = ComputerUseTypeTextNormalization.normalizedTypeAction(from: "hello world")
        XCTAssertEqual(normalized.textToType, "hello world")
        XCTAssertFalse(normalized.shouldPressReturnAfterTyping)
    }
}
