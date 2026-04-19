//
//  AdaptiveOutputRouter.swift
//  claude-cursor
//
//  Decides which output surface a given Claude response should be rendered
//  on. Claude's responses vary in shape: a quick "click this button" should
//  go through the cursor pointing pipeline, an in-depth "here's how Resolve's
//  color page works" should open the Answer panel, and a casual reply should
//  just play via TTS next to the cursor.
//
//  The router is a pure decision function — it classifies a response and
//  returns the chosen surface. The caller (CompanionManager) is responsible
//  for actually dispatching to the right subsystem (overlay, panel, lesson
//  engine).
//

import Foundation

// MARK: - Output Surface

/// The surface on which a Claude response should be rendered. Each surface
/// has different affordances — navigation is ephemeral cursor pointing,
/// answer is a persistent scrollable panel, lesson uses the step overlay,
/// and chat is spoken-only with no persistent panel.
enum CompanionOutputSurface: Equatable, CustomStringConvertible {

    /// Claude called the `point_at_element` tool at least once during the
    /// turn — the cursor flies to the element (the tool executor already
    /// published the target) and the spoken reply plays next to it. No
    /// persistent panel is shown.
    case navigation

    /// The response is part of a structured lesson (contains a `[STEP:...]`
    /// tag or the system is already in lesson mode). The lesson overlay
    /// handles rendering.
    case lesson

    /// The response is a long-form explanation, breakdown, or how-to that
    /// benefits from a readable panel. The Answer panel is shown with the
    /// full text; TTS plays a brief summary indicating the panel was opened.
    case answer

    /// The response is a short conversational reply. Rendered as full TTS
    /// with no persistent panel.
    case chat

    var description: String {
        switch self {
        case .navigation: return "navigation"
        case .lesson: return "lesson"
        case .answer: return "answer"
        case .chat: return "chat"
        }
    }
}

// MARK: - Router Input

/// The signals the router uses to classify a response. Passed in as a
/// struct so additional signals (confidence scores, prior mode, etc.) can be
/// added over time without breaking the call sites.
struct AdaptiveOutputRouterInput {

    /// The full spoken response text from Claude. Coordinate payloads
    /// never appear in this text anymore — they're delivered via
    /// tool-use — but `[STEP:...]` tags still trigger lesson routing.
    let fullResponseText: String

    /// Whether the `point_at_element` tool fired at least once during
    /// this turn. The caller (CompanionManager) reads this from
    /// `CompanionToolRegistry.didPointingToolFireInCurrentTurn` right
    /// after the tool-use loop returns.
    let didResponseIncludePointTag: Bool

    /// Whether the system is currently in a structured lesson (i.e. the
    /// `LessonStateMachine.currentMode` is `.lesson`). If true, the router
    /// will strongly prefer routing to the lesson overlay.
    let isCurrentlyInLessonMode: Bool

    /// Whether the user explicitly typed their message in the chat window
    /// (as opposed to using push-to-talk). Typed questions often want a
    /// readable panel response rather than a spoken reply.
    let didUserSubmitViaChatInput: Bool
}

// MARK: - Router

/// Decides which output surface a Claude response should render on. Pure
/// classification logic — no side effects, no state — so it's trivially
/// testable and easy to reason about in isolation.
enum AdaptiveOutputRouter {

    /// Decides the surface for the given response. Priority order:
    ///   1. Lesson — if in lesson mode or the response includes a `[STEP:...]`
    ///      tag, the lesson overlay owns the response.
    ///   2. Navigation — if Claude called `point_at_element` during the
    ///      turn (and we're not in lesson mode), it's a pointing gesture.
    ///   3. Answer — math / LaTeX markup or a fenced code block. Both
    ///      render unreadably in the cursor bubble and must go to the
    ///      Answer panel's markdown + MathJax + Prism renderer.
    ///   4. Chat — everything else stays spoken-only (no panel),
    ///      regardless of length, paragraph count, list shape,
    ///      heading presence, or whether the user typed it.
    ///
    /// Narrowed in the April 2026 UX pass: the prior "long-form" branch
    /// pulled any multi-paragraph / multi-bullet / typed / >220-char
    /// response into the docked panel, which made casual prose feel
    /// heavyweight. The user's strict rule is now: the panel is reserved
    /// for math and code.
    static func decideOutputSurface(
        for routerInput: AdaptiveOutputRouterInput
    ) -> CompanionOutputSurface {

        let responseText = routerInput.fullResponseText

        // ── Rule 1: Lesson takes precedence ──────────────────────────────
        // If we're already running a lesson, every assistant response is
        // part of that lesson. Also, an explicit [STEP:...] tag always
        // routes to the lesson overlay even outside lesson mode (the tag
        // implies the user asked for a tutorial-style breakdown).
        let responseContainsStepTag = responseText.range(
            of: "\\[STEP:[^\\]]*\\]",
            options: .regularExpression
        ) != nil

        if routerInput.isCurrentlyInLessonMode || responseContainsStepTag {
            return .lesson
        }

        // ── Rule 2: Navigation ───────────────────────────────────────────
        // A pointing gesture is a visual action — speak the short response
        // next to the cursor, don't open the heavy panel.
        if routerInput.didResponseIncludePointTag {
            return .navigation
        }

        // ── Rule 3: Math / LaTeX → Answer panel ──────────────────────────
        // Math responses render awfully in spoken-only mode —
        // fractions, integrals, and subscripts need the Answer panel where
        // MathJax can typeset them. Any balanced LaTeX delimiter pair
        // forces the panel regardless of length.
        if containsMathOrLatexMarkup(responseText) {
            return .answer
        }

        // ── Rule 4: Fenced code → Answer panel ───────────────────────────
        // A fenced code block (``` … ```) is the only other content type
        // that requires the panel — it needs Prism syntax highlighting and
        // horizontal scroll that the cursor pill can't provide.
        if responseText.contains("```") {
            return .answer
        }

        // ── Rule 5: Chat (fallback) ──────────────────────────────────────
        // Everything else — prose, lists, multi-paragraph explanations,
        // typed input — stays in the compact cursor pill.
        return .chat
    }

    /// Returns true when the response contains LaTeX / math markup that
    /// needs the Answer panel's markdown renderer to display correctly.
    /// Matches the standard delimiters: `$$...$$`, `\(...\)`, `\[...\]`,
    /// and balanced inline `$...$` pairs. Single stray dollar signs don't
    /// trigger the rule because they're common in code and prose.
    private static func containsMathOrLatexMarkup(_ responseText: String) -> Bool {
        // Block delimiters: $$...$$ with content between.
        if responseText.range(
            of: "\\$\\$[^\\$]+\\$\\$",
            options: .regularExpression
        ) != nil {
            return true
        }

        // LaTeX inline `\( ... \)` and display `\[ ... \]` — escaped so
        // they survive prose and don't collide with regex groups.
        if responseText.range(
            of: "\\\\\\([^\\)]+\\\\\\)",
            options: .regularExpression
        ) != nil {
            return true
        }
        if responseText.range(
            of: "\\\\\\[[^\\]]+\\\\\\]",
            options: .regularExpression
        ) != nil {
            return true
        }

        // Balanced single-dollar inline math: `$...$` with no nested `$`
        // inside and at least one character. Requires two `$` on the same
        // line to avoid matching code like `cost is $5 per $10 plan`.
        if responseText.range(
            of: "\\$[^\\$\\n]{1,80}\\$",
            options: .regularExpression
        ) != nil {
            // Require the presence of a math-ish hint (letter-digit juxtaposition,
            // superscript caret, backslash command, or fraction slash) so plain
            // dollar-amount prose doesn't trip the rule.
            let mathHintPattern = "\\$[^\\$\\n]*([a-zA-Z]\\^|\\\\[a-zA-Z]+|_\\{|\\^\\{|[a-zA-Z]/[a-zA-Z]|\\d[a-zA-Z])[^\\$\\n]*\\$"
            if responseText.range(of: mathHintPattern, options: .regularExpression) != nil {
                return true
            }
        }

        return false
    }

}
