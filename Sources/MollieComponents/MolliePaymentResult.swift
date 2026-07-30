import MollieCore

/// Terminal outcome of the callback-style entry points —
/// `MollieCheckout.presentCard(from:)` and `MollieCardComponent`'s
/// `onResult` callback.
///
/// For an observable alternative that also surfaces non-terminal states
/// (`.processing`, `.challengePresented`, `.cancelled`, `.attemptFailed`),
/// see `MollieCheckout.events` / `eventsPublisher` and `MollieCheckoutEvent`.
/// Both styles are fully supported: pick the one that fits the host — a
/// single awaited/callback result here, or the session-shaped event stream
/// there.
///
/// Marked `@unchecked Sendable` because `MollieError` wraps non-Sendable
/// Foundation error types (`URLError`, `DecodingError`, generic `Error`).
/// In practice the result is constructed on a single actor and handed off
/// to the awaiting caller, so cross-thread mutation is not a hazard;
/// the `@unchecked` annotation mirrors the precedent set by
/// `MollieCore.AnyCodable`.
public enum MolliePaymentResult: @unchecked Sendable {
    case completed(MolliePayment)
    case failed(MollieError)
    case cancelled
}

extension MolliePaymentResult {
    /// Derives the one-shot terminal result from the session-shaped
    /// `MollieCheckoutEvent`. Only meaningful for the
    /// checkout event's terminal cases and `.cancelled` — the three
    /// outcomes a single `CardPaymentResult` can already produce today (see
    /// `CardCheckoutRunner.mapFinalEvent(cardResult:)`, the only caller).
    init(checkoutEvent: MollieCheckoutEvent) {
        switch checkoutEvent {
        case let .completed(payment):
            self = .completed(payment)
        case let .failed(error):
            self = .failed(error)
        case .cancelled:
            self = .cancelled
        case let .attemptFailed(_, error):
            // `mapFinalEvent(cardResult:)` does produce this case (a
            // retryable soft decline), but the deprecated
            // `MolliePaymentResult` has no shape for a non-terminal outcome —
            // fold it into `.failed` so this initializer stays total. Callers
            // that need the real signal use `MollieCheckout.events`/
            // `eventsPublisher` instead, which carry `MollieCheckoutEvent`
            // directly.
            self = .failed(error)
        case .processing, .challengePresented:
            // Not reachable from `mapFinalEvent(cardResult:)` today — those
            // cases only ever come from the coordinator's `onEvent` ticks,
            // which flow into the checkout's stream directly and never
            // through this initializer.
            self = .failed(.unknown(MollieCheckoutEventNotTerminalError()))
        }
    }
}

/// Marker error for the (unreachable in practice) non-terminal →
/// terminal-result conversion above.
struct MollieCheckoutEventNotTerminalError: Error {}
