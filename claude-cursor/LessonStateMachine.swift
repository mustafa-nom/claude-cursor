//
//  LessonStateMachine.swift
//  claude-cursor
//
//  Manages the high-level companion mode — what ClaudeCursor is currently
//  doing for the user. Prevents conflicting modes from running simultaneously
//  (e.g., a YouTube lesson and tutor mode observing at the same time).
//
//  This sits above CompanionVoiceState, which tracks the low-level voice
//  pipeline (idle/listening/processing/responding). A companion mode like
//  .lesson or .tutor can be active while the voice state cycles through
//  its own transitions independently.
//

import Combine
import Foundation

/// The high-level mode that ClaudeCursor is operating in. Only one mode
/// can be active at a time. Transitions are validated so conflicting
/// modes never overlap.
enum CompanionMode: Equatable, CustomStringConvertible {
    /// No active mode — the companion is waiting for user interaction.
    case idle

    /// Push-to-talk Q&A with cursor pointing to UI elements on screen.
    /// The user asked a question and ClaudeCursor is navigating to / pointing
    /// at relevant elements.
    case navigation

    /// Proactive tutor mode — periodically observing the user's screen during
    /// idle moments and offering guidance. Can be interrupted by voice input.
    case tutor

    /// Following a YouTube tutorial step-by-step with overlay instructions,
    /// PiP video, and progress tracking. Exclusive — other modes are paused
    /// until the lesson ends or is cancelled.
    case lesson

    /// Displaying a detailed answer in the persistent answer panel (not just
    /// cursor speech bubble). Used for knowledge-heavy or multi-paragraph responses.
    case answer

    /// The chat transcript window is active and the user is interacting via
    /// text input rather than (or in addition to) voice.
    case chat

    var description: String {
        switch self {
        case .idle:       return "idle"
        case .navigation: return "navigation"
        case .tutor:      return "tutor"
        case .lesson:     return "lesson"
        case .answer:     return "answer"
        case .chat:       return "chat"
        }
    }
}

/// Validates and manages transitions between companion modes. Ensures only
/// one mode is active at a time and that transitions are intentional.
///
/// Usage: CompanionManager owns a single LessonStateMachine instance and
/// calls `requestTransition(to:)` before entering a new mode. The state
/// machine either approves the transition (returning true) or rejects it
/// (returning false) if the current mode must be explicitly exited first.
@MainActor
final class LessonStateMachine: ObservableObject {

    /// The current companion mode. Published so UI can react to mode changes.
    @Published private(set) var currentMode: CompanionMode = .idle

    /// Timestamp when the current mode was entered, for analytics and
    /// rate-limiting decisions.
    private(set) var currentModeEnteredAt: Date = Date()

    /// The mode that was active before the current one, useful for
    /// returning to a previous state (e.g., after answering a question
    /// during a lesson, return to .lesson).
    private(set) var previousMode: CompanionMode = .idle

    /// Attempts to transition to a new mode. Returns true if the transition
    /// was accepted, false if the current mode blocks it.
    ///
    /// **Transition rules:**
    /// - Any mode can transition to `.idle` (always allowed — this is "stop").
    /// - `.idle` can transition to any mode (nothing to conflict with).
    /// - `.lesson` is exclusive — it blocks transitions to `.tutor` and vice
    ///   versa. The user must exit the lesson before tutor mode can activate.
    /// - `.navigation` and `.answer` are transient — they can be entered from
    ///   most modes and return to the previous mode when done.
    /// - `.chat` can coexist with `.tutor` (the chat window is just a UI
    ///   surface, not a conflicting pipeline).
    @discardableResult
    func requestTransition(to targetMode: CompanionMode) -> Bool {
        // Transitioning to the same mode is a no-op success
        if targetMode == currentMode {
            return true
        }

        // Always allow transitioning to idle (stop everything)
        if targetMode == .idle {
            performTransition(to: .idle)
            return true
        }

        // From idle, any mode is reachable
        if currentMode == .idle {
            performTransition(to: targetMode)
            return true
        }

        // Lesson mode is exclusive — block conflicting modes
        if currentMode == .lesson {
            switch targetMode {
            case .tutor:
                // Cannot start tutor while in a lesson
                print("⚠️ LessonStateMachine: blocked transition from .lesson → .tutor (lesson is exclusive)")
                return false
            case .navigation, .answer:
                // Navigation and answer are allowed within a lesson
                // (user can ask questions while following along)
                performTransition(to: targetMode)
                return true
            case .chat:
                // Chat window can open during a lesson
                performTransition(to: targetMode)
                return true
            case .idle, .lesson:
                // Already handled above
                performTransition(to: targetMode)
                return true
            }
        }

        // Tutor mode blocks lesson (must exit tutor first to start a lesson)
        if currentMode == .tutor && targetMode == .lesson {
            print("⚠️ LessonStateMachine: blocked transition from .tutor → .lesson (exit tutor first)")
            return false
        }

        // All other transitions are allowed
        performTransition(to: targetMode)
        return true
    }

    /// Forces a transition regardless of rules. Use sparingly — only for
    /// situations like app cleanup or error recovery where the state machine
    /// must be reset.
    func forceTransition(to targetMode: CompanionMode) {
        performTransition(to: targetMode)
    }

    /// Returns to the previous mode. Useful after a transient mode like
    /// `.answer` or `.navigation` completes.
    @discardableResult
    func returnToPreviousMode() -> CompanionMode {
        let returnTarget = previousMode
        performTransition(to: returnTarget)
        return returnTarget
    }

    /// Whether the current mode allows tutor idle observations to fire.
    /// Tutor observations should only run when the companion is in tutor
    /// mode — not during lessons, active navigation, or answer display.
    var canTutorObserve: Bool {
        currentMode == .tutor
    }

    /// Whether the current mode allows push-to-talk voice input.
    /// Voice input is allowed in most modes (it interrupts gracefully)
    /// but may be suppressed during certain lesson steps.
    var canAcceptVoiceInput: Bool {
        switch currentMode {
        case .idle, .navigation, .tutor, .answer, .chat:
            return true
        case .lesson:
            // Voice input is allowed during lessons — the user might
            // ask a question about the current step
            return true
        }
    }

    // MARK: - Private

    private func performTransition(to targetMode: CompanionMode) {
        let fromMode = currentMode
        previousMode = fromMode
        currentMode = targetMode
        currentModeEnteredAt = Date()
        print("🔄 LessonStateMachine: \(fromMode) → \(targetMode)")
    }
}
