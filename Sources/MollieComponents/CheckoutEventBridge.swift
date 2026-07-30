import Combine
import Foundation

/// Backing store for `MollieCheckout`'s observable event stream.
///
/// `MollieCheckout` is a `Sendable` struct, so it cannot itself hold mutable
/// broadcast state (a `PassthroughSubject` plus live `AsyncStream`
/// continuations) across copies. This reference type is that shared state:
/// every copy of the same `MollieCheckout` value, and every attempt run
/// through it (`presentCard`/`makeCardComponent`), funnels into the SAME
/// bridge instance.
///
/// This also encodes the "session stays open across attempts" model at the
/// stream level: only a genuinely terminal `MollieCheckoutEvent`
/// (`.completed`/`.failed`) finishes the stream. Non-terminal events —
/// including `.cancelled`, which ends an attempt but not the session — keep
/// the stream open for a subsequent attempt's events.
final class CheckoutEventBridge: @unchecked Sendable {
    private let lock = NSLock()
    private let subject = PassthroughSubject<MollieCheckoutEvent, Never>()
    private var continuations: [Int: AsyncStream<MollieCheckoutEvent>.Continuation] = [:]
    private var nextContinuationID = 0
    private var isFinished = false

    var publisher: AnyPublisher<MollieCheckoutEvent, Never> {
        subject.eraseToAnyPublisher()
    }

    /// Vends a fresh, independent `AsyncStream` tapping the same underlying
    /// events — multiple concurrent consumers (or repeated `for await` loops
    /// across attempts) each get their own continuation. A stream requested
    /// after the bridge has already finished (a terminal event fired) ends
    /// immediately, matching Combine's replay-nothing-after-completion
    /// behaviour on `subject`.
    func makeStream() -> AsyncStream<MollieCheckoutEvent> {
        AsyncStream { continuation in
            lock.lock()
            guard !isFinished else {
                lock.unlock()
                continuation.finish()
                return
            }
            let id = nextContinuationID
            nextContinuationID += 1
            continuations[id] = continuation
            lock.unlock()
            continuation.onTermination = { [weak self] _ in
                self?.removeContinuation(id)
            }
        }
    }

    func emit(_ event: MollieCheckoutEvent) {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        let terminal = event.isTerminal
        let activeContinuations = Array(continuations.values)
        if terminal {
            isFinished = true
            continuations.removeAll()
        }
        lock.unlock()

        subject.send(event)
        for continuation in activeContinuations {
            continuation.yield(event)
        }
        if terminal {
            subject.send(completion: .finished)
            for continuation in activeContinuations {
                continuation.finish()
            }
        }
    }

    private func removeContinuation(_ id: Int) {
        lock.lock()
        continuations.removeValue(forKey: id)
        lock.unlock()
    }
}
