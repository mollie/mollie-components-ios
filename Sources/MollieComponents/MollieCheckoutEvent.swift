import Foundation
import MollieCore

/// Session-shaped, observable outcome of a `MollieCheckout` — the
/// successor to the one-shot `MolliePaymentResult`.
///
/// Terminal cases end the checkout's session outright. Non-terminal cases
/// report progress while the session stays open for a further attempt —
/// e.g. after `.cancelled`, the merchant can re-present the card form on
/// the SAME `MollieCheckout` and the resulting attempt still feeds this
/// same event stream.
///
/// `isTerminal` mirrors `SessionEventMapper.isTerminal(_:)` — the sole
/// source of truth for the wire-level terminal/non-terminal split — but is
/// expressed directly over this type's own cases rather than delegating at
/// runtime, since `MollieCheckoutEvent`'s payloads (`MolliePayment`,
/// `MollieError`) differ in shape from `ChannelEvent`'s. The mapping
/// functions in `CardCheckoutRunner` (`mapNonTerminalEvent`/
/// `mapFinalEvent`) are the bridge between the two, and a dedicated test
/// pins their classifications together so they cannot drift.
///
/// Marked `@unchecked Sendable` for the same reason as `MolliePaymentResult`:
/// `MollieError` wraps non-Sendable Foundation error types.
public enum MollieCheckoutEvent: @unchecked Sendable {
    // MARK: Terminal — the session has ended.

    /// The session completed successfully.
    case completed(MolliePayment)
    /// The session ended in failure (network/tokenisation/3DS/session error).
    case failed(MollieError)

    // MARK: Non-terminal — the session stays open.

    /// A single payment attempt failed but the session accepts another
    /// attempt.
    ///
    /// Emitted when the engine's `CardPaymentResult
    /// .attemptFailed` (a bare `reset` or an `error` with `params.reset ==
    /// true`) indicates the server already reset the session to `CREATED`.
    /// `retryable` is always `true` on this path — see
    /// `CardCheckoutRunner.mapFinalEvent(cardResult:)`, the sole mapping
    /// site, for why.
    case attemptFailed(retryable: Bool, error: MollieError)
    /// The user cancelled the current attempt (closed the sheet, tapped
    /// Cancel). The session itself remains open for a retry.
    case cancelled
    /// A session snapshot was observed while polling/listening — no
    /// terminal state yet.
    case processing(SessionResponse)
    /// A 3-D Secure challenge or redirect page was presented to the user.
    case challengePresented(URL)

    /// True for the two cases that end the session outright. Mirrors
    /// `SessionEventMapper.isTerminal(_:)` — see that type's doc comment
    /// for the wire-level classification this must stay in lockstep with.
    public var isTerminal: Bool {
        switch self {
        case .completed, .failed: true
        case .attemptFailed, .cancelled, .processing, .challengePresented: false
        }
    }
}
