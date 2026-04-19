//
//  ClipboardManager.swift
//  claude-cursor
//
//  Centralized clipboard helpers for copying Claude responses to the system
//  pasteboard. Strips internal coordination tags (`[POINT:...]`, `[STEP:...]`)
//  so only the user-facing prose lands on the clipboard — the user should
//  never see these tags when they paste the response elsewhere.
//
//  All auto-copy paths should go through `ClipboardManager.copyResponseToClipboard`
//  rather than writing to `NSPasteboard` directly so the stripping rules
//  stay consistent across voice responses, chat replies, and answer-panel
//  content.
//

import AppKit
import Foundation

/// Namespaced helper for writing Claude responses to the system clipboard
/// with internal tags stripped.
enum ClipboardManager {

    // MARK: - Public API

    /// Copies the given response text to the general pasteboard, stripping
    /// any internal coordination tags first. No-ops if the cleaned text is
    /// empty (we don't want to wipe the user's clipboard with nothing).
    ///
    /// - Parameter rawResponseText: The full response text from Claude,
    ///   potentially containing `[POINT:...]` and `[STEP:...]` tags.
    /// - Returns: The cleaned text that was copied to the clipboard, or nil
    ///   if nothing was copied (empty input after stripping).
    @discardableResult
    static func copyResponseToClipboard(rawResponseText: String) -> String? {
        let cleanedResponseText = stripInternalCoordinationTags(from: rawResponseText)

        guard !cleanedResponseText.isEmpty else {
            return nil
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(cleanedResponseText, forType: .string)

        return cleanedResponseText
    }

    /// Strips all internal coordination tags from the given text without
    /// touching the pasteboard. Useful when the caller needs the cleaned
    /// text for display (e.g. chat transcript) rather than clipboard copy.
    ///
    /// Current tags stripped:
    /// - `[POINT:x,y:label:screenN]` — cursor pointing coordinates consumed
    ///   by the overlay, never shown to the user.
    /// - `[STEP:index:totalSteps:title]` — lesson step markers consumed by
    ///   the lesson overlay.
    static func stripInternalCoordinationTags(from responseText: String) -> String {
        var cleaned = responseText

        cleaned = cleaned.replacingOccurrences(
            of: "\\[POINT:[^\\]]*\\]",
            with: "",
            options: .regularExpression
        )
        cleaned = cleaned.replacingOccurrences(
            of: "\\[STEP:[^\\]]*\\]",
            with: "",
            options: .regularExpression
        )

        // Collapse any double spaces left behind by removed tags so the
        // pasted text reads cleanly. We only collapse runs inside lines,
        // not across newlines, to preserve paragraph structure.
        cleaned = cleaned.replacingOccurrences(
            of: "[ \\t]{2,}",
            with: " ",
            options: .regularExpression
        )

        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
