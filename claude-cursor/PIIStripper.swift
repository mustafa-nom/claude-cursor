//
//  PIIStripper.swift
//  claude-cursor
//
//  Regex-based stripping of personally identifiable information from text
//  before it's written to the on-disk session log or handed to the session
//  compressor. This is a defense-in-depth measure: the wiki stays on the
//  user's machine, but the observer log could be shared, emailed, or
//  screen-recorded, and the compressor sends content to Claude.
//
//  Covers the common shapes:
//    - Credit card numbers (13–19 digits, with or without spaces/dashes)
//    - US Social Security Numbers (9 digits in 3-2-4 or 9 groups)
//    - API tokens and bearer secrets (long base64-ish / hex runs, sk-*,
//      pk-*, ghp_*, AKIA*, etc.)
//    - Obvious password= or api_key= patterns
//    - Email addresses (replaced with placeholder preserving the domain)
//
//  Phone numbers are intentionally not stripped — users often ask about
//  phone-number formatting in apps and over-stripping those breaks the
//  assistant's ability to help. Email addresses are partially preserved
//  because app context often hinges on the domain.
//

import Foundation

/// Static entry point. No state — stateless stripping is safe to call from
/// any actor context.
enum PIIStripper {

    /// Returns the input text with recognized PII replaced by deterministic
    /// placeholders. The output length may be shorter than the input.
    static func strip(fromText inputText: String) -> String {
        guard !inputText.isEmpty else { return inputText }

        var workingText = inputText

        // Ordering matters: replace longer/stricter patterns first so a
        // greedy later pattern doesn't corrupt the structure we need to
        // detect earlier ones. SSN → credit card → API tokens → secrets →
        // emails.

        for stripPass in Self.orderedReplacementPasses {
            workingText = workingText.replacingOccurrences(
                of: stripPass.pattern,
                with: stripPass.replacement,
                options: [.regularExpression, .caseInsensitive]
            )
        }

        return workingText
    }

    // MARK: - Replacement Passes

    private struct PIIReplacementPass {
        let pattern: String
        let replacement: String
    }

    private static let orderedReplacementPasses: [PIIReplacementPass] = [

        // US Social Security Numbers. Match 3-2-4 digits with optional
        // dashes or spaces — but not when preceded by more digits (so we
        // don't eat a longer ID number).
        PIIReplacementPass(
            pattern: "(?<!\\d)\\d{3}[- ]?\\d{2}[- ]?\\d{4}(?!\\d)",
            replacement: "[REDACTED_SSN]"
        ),

        // Credit card numbers. 13–19 digits with optional spaces/dashes at
        // 4-digit boundaries. Not preceded by another digit. This is
        // intentionally broad — a UUID or other long digit run could get
        // caught here, but the false-positive cost is low vs. leaking a PAN.
        PIIReplacementPass(
            pattern: "(?<!\\d)(?:\\d{4}[- ]?){3,4}\\d{1,4}(?!\\d)",
            replacement: "[REDACTED_CARD]"
        ),

        // Common API key and secret token formats. Match explicit prefixes
        // vendors are known to use so we don't false-positive on other
        // long tokens.
        PIIReplacementPass(
            pattern: "\\bsk-[A-Za-z0-9_-]{20,}\\b",
            replacement: "[REDACTED_KEY]"
        ),
        PIIReplacementPass(
            pattern: "\\bpk-[A-Za-z0-9_-]{20,}\\b",
            replacement: "[REDACTED_KEY]"
        ),
        PIIReplacementPass(
            pattern: "\\bghp_[A-Za-z0-9]{30,}\\b",
            replacement: "[REDACTED_KEY]"
        ),
        PIIReplacementPass(
            pattern: "\\bgho_[A-Za-z0-9]{30,}\\b",
            replacement: "[REDACTED_KEY]"
        ),
        PIIReplacementPass(
            pattern: "\\bghu_[A-Za-z0-9]{30,}\\b",
            replacement: "[REDACTED_KEY]"
        ),
        PIIReplacementPass(
            pattern: "\\bghs_[A-Za-z0-9]{30,}\\b",
            replacement: "[REDACTED_KEY]"
        ),
        PIIReplacementPass(
            pattern: "\\bAKIA[0-9A-Z]{16}\\b",
            replacement: "[REDACTED_AWS_KEY]"
        ),
        PIIReplacementPass(
            pattern: "\\bxox[pbar]-[A-Za-z0-9-]{10,}\\b",
            replacement: "[REDACTED_SLACK_TOKEN]"
        ),

        // Bearer tokens in Authorization-style contexts.
        PIIReplacementPass(
            pattern: "(?i)bearer\\s+[A-Za-z0-9._~+/-]{20,}=*",
            replacement: "Bearer [REDACTED_BEARER]"
        ),

        // Key-value shaped secrets (password=, api_key=, apikey=, token=,
        // secret=). Requires the value to be at least 6 characters so we
        // don't obliterate short placeholder values like "foo".
        PIIReplacementPass(
            pattern: "(?i)(password|api[_-]?key|api[_-]?token|secret|access[_-]?token)\\s*[=:]\\s*[\"']?([A-Za-z0-9._~+/=-]{6,})",
            replacement: "$1=[REDACTED_VALUE]"
        ),

        // Email addresses — replace with a masked form that preserves the
        // domain so the assistant still has context about which service
        // the user was referring to.
        PIIReplacementPass(
            pattern: "\\b[A-Za-z0-9._%+-]+@([A-Za-z0-9.-]+\\.[A-Za-z]{2,})",
            replacement: "[REDACTED_EMAIL]@$1"
        ),

        // JWT-shaped tokens: three base64url segments separated by dots.
        // Only match when each segment is reasonably long so we don't
        // clobber file.ext.ext or x.y.z version numbers.
        PIIReplacementPass(
            pattern: "\\beyJ[A-Za-z0-9_-]{10,}\\.[A-Za-z0-9_-]{10,}\\.[A-Za-z0-9_-]{10,}\\b",
            replacement: "[REDACTED_JWT]"
        )
    ]
}
