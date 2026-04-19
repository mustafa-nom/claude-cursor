//
//  CursorPillTypewriter.swift
//  claude-cursor
//
//  Streams text into a cursor-pill bubble one character at a time with a
//  configurable per-character delay. Consumers iterate the returned
//  `AsyncStream` and apply each character to their own @Published text
//  state, keeping the typewriter itself UI-agnostic so the navigation
//  bubble and the consent pill can share it verbatim.
//
//  Cancellation semantics:
//    - `cancelCurrentStream()` is idempotent and terminal. It cancels the
//      underlying Task, yields `.cancelled` on the AsyncStream continuation,
//      and finishes it. After the call returns, no NEW `.character` events
//      will be yielded on the old stream.
//    - A `.character` that was already buffered on the AsyncStream at the
//      moment of cancellation may still be delivered to the consumer before
//      `.cancelled` arrives. Consumers must treat `.cancelled` as the
//      terminal event rather than assuming no further `.character` events
//      can follow. Phase 1 consumers (consent pill) hide their UI on cancel
//      so a late character is harmless.
//    - Starting a new `stream(...)` automatically cancels any prior stream
//      first. Callers never need to track stream generations themselves.
//

import Foundation

enum CursorPillStreamEvent {
    case character(Character)
    case completed
    case cancelled
}

@MainActor
final class CursorPillTypewriter {

    private var activeStreamContinuation: AsyncStream<CursorPillStreamEvent>.Continuation?
    private var activeStreamTask: Task<Void, Never>?
    private var activeStreamToken: UUID?

    /// Starts a new stream for `text`. Any prior stream is cancelled first
    /// — its AsyncStream yields `.cancelled` and finishes before the new
    /// one is handed back. `characterDelay` is sampled once per character
    /// so the cadence jitters slightly (matches the navigation-bubble
    /// reveal).
    func stream(
        text: String,
        characterDelay: ClosedRange<Duration> = .milliseconds(30)...(.milliseconds(60))
    ) -> AsyncStream<CursorPillStreamEvent> {
        cancelCurrentStream()

        let (streamToReturn, streamContinuation) = AsyncStream<CursorPillStreamEvent>.makeStream()
        let newStreamToken = UUID()

        activeStreamContinuation = streamContinuation
        activeStreamToken = newStreamToken

        let lowerDelaySeconds = durationInSeconds(characterDelay.lowerBound)
        let upperDelaySeconds = durationInSeconds(characterDelay.upperBound)
        let clampedLowerSeconds = max(0, min(lowerDelaySeconds, upperDelaySeconds))
        let clampedUpperSeconds = max(clampedLowerSeconds, upperDelaySeconds)

        activeStreamTask = Task { @MainActor [weak self] in
            // Guarantee the continuation finishes on every exit path — token
            // mismatch early return, cancellation, or normal completion. A
            // missed `finish()` leaves the consumer's `for await` loop hung
            // forever, which manifests as a stranded pill on the cursor
            // overlay.
            defer { streamContinuation.finish() }

            for character in text {
                if Task.isCancelled { return }
                guard let self, self.activeStreamToken == newStreamToken else { return }

                streamContinuation.yield(.character(character))

                let randomDelaySeconds = Double.random(
                    in: clampedLowerSeconds...clampedUpperSeconds
                )
                try? await Task.sleep(for: .seconds(randomDelaySeconds))
            }

            if Task.isCancelled { return }
            guard let self, self.activeStreamToken == newStreamToken else { return }

            self.activeStreamToken = nil
            self.activeStreamContinuation = nil
            self.activeStreamTask = nil

            streamContinuation.yield(.completed)
        }

        return streamToReturn
    }

    /// Idempotent. Cancels the in-flight Task, yields `.cancelled` on the
    /// active continuation (if any), then finishes it. Safe to call
    /// repeatedly; subsequent calls are no-ops.
    func cancelCurrentStream() {
        let continuationToCancel = activeStreamContinuation
        activeStreamToken = nil
        activeStreamContinuation = nil
        activeStreamTask?.cancel()
        activeStreamTask = nil

        continuationToCancel?.yield(.cancelled)
        continuationToCancel?.finish()
    }
}

/// Converts a `Duration` into fractional seconds. Used to pick a random
/// per-character delay via `Double.random(in:)` since `Duration` itself
/// isn't directly rangeable.
private func durationInSeconds(_ duration: Duration) -> Double {
    let components = duration.components
    return Double(components.seconds)
        + Double(components.attoseconds) / 1_000_000_000_000_000_000.0
}
