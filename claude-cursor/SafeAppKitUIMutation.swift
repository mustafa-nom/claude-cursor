//
//  SafeAppKitUIMutation.swift
//  claude-cursor
//
//  Thin Swift wrapper around the ObjC `runBlockCatchingNSException` bridge.
//  Centralizes logging so every AppKit boundary we guard produces a
//  consistent, greppable Console.app line when something goes wrong.
//
//  Only use at AppKit / NSHostingView boundaries where NSException paths
//  are a documented risk (layout recursion, invalid argument asserts).
//  For regular Swift-throwing code, use `do`/`try`/`catch`.
//

import Foundation
import OSLog

private let appKitExceptionLogger = Logger(
    subsystem: "com.claudecursor.app",
    category: "NSException"
)

/// Runs `mutation` and captures any `NSException` it throws via the ObjC
/// bridge. Returns `nil` on success, or a human-readable diagnostic string
/// on failure (already logged via `OSLog`).
///
/// `operationLabel` should identify the call site so the log line is
/// greppable — e.g. `"CursorBubbleConsent.positionPanel"`.
@MainActor
@discardableResult
func runAppKitMutationCatchingNSException(
    operationLabel: String,
    _ mutation: () -> Void
) -> String? {
    let caughtException = runBlockCatchingNSException { mutation() }
    guard let caughtException else { return nil }

    let exceptionName = caughtException.name.rawValue
    let exceptionReason = caughtException.reason ?? "nil"
    let diagnostic = "[\(operationLabel)] \(exceptionName): \(exceptionReason)"

    appKitExceptionLogger.error("\(diagnostic, privacy: .public)")
    return diagnostic
}
