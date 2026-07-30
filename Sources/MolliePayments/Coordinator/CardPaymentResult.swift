import MollieCore

/// Terminal outcome of `CardPaymentCoordinator.submit`.
///
/// `MollieError` itself is not `Equatable`, so this enum does
/// not synthesize `Equatable`. Tests inspect cases via pattern matching.
/// Made public for demo target access; will be re-evaluated once the `MollieComponents` umbrella target ships.
public enum CardPaymentResult {
    case completed(SessionResponse)
    case failed(MollieError)
    case cancelled
    /// This ONE submit attempt ended in a retryable
    /// soft-decline (`ChannelEvent.attemptFailed` — bare `reset`, or `error`
    /// with `params.reset == true`). Like `.cancelled`, this ends the
    /// current `submit(_:)` call but NOT the underlying session: the server
    /// has already reset it to `CREATED`, so a fresh `submit(_:)` (new
    /// tokenize + new checkout-attempt/PATCH) is accepted without any
    /// `cancel-authentication` cleanup call. See
    /// `CardPaymentCoordinator.handleAttemptFailed`.
    case attemptFailed(ProblemDetails?)
}
