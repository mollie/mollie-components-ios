import Foundation

/// Events emitted by a `MollieChannelsClient` while a session is in flight.
///
/// Equatable is synthesized: all associated value types (`SessionResponse`,
/// `URL`, `ProblemDetails?`) conform to Equatable. `SessionResponse` Equatable
/// is backed by `AnyCodable`'s NSObject-bridging Equatable (see AnyCodable.swift).
/// Made public so MollieChannelsClient (public for demo target access) can reference it.
/// Will be re-evaluated once the `MollieComponents` umbrella target ships.
public enum ChannelEvent: Equatable {
    case sessionUpdated(SessionResponse)
    case threeDSChallengeReady(URL)
    /// Server emitted a `redirect` next-action: the SDK must present the
    /// supplied URL (Mollie's hosted prepare-authentication / final-screen
    /// page) and then resume polling. **Not terminal** — only
    /// `sessionCompleted` (status flipped to `.completed`) is. Mapping
    /// `redirect` straight to `sessionCompleted` was the source of
    /// "Payment completed" UI on payments that never actually completed
    /// at the card processor; the comment on
    /// `SessionEventConsumer.map` documents the wire shape.
    case redirectRequired(URL)
    /// Retryable soft-decline: server emitted `nextAction
    /// .actionType == "error"` with the literal `params.reset == true`
    /// marker (authentication/authorization declined — session resets to
    /// `CREATED`, non-final), or a bare `actionType == "reset"` (shopper
    /// cancelled 3DS). **Not terminal** — the session accepts another
    /// attempt. Carries whatever `ProblemDetails` `SessionEventMapper` could
    /// synthesize from `params` (`nil` when the wire payload has none, e.g.
    /// the bare-reset/cancel case). See `SessionEventMapper.map` for the
    /// wire-level decision rule and citations. Eventually feeds
    /// `MollieCheckoutEvent.attemptFailed` once the coordinator/runner wiring
    /// lands (tracked separately).
    case attemptFailed(ProblemDetails?)
    case sessionCompleted(SessionResponse)
    case sessionFailed(ProblemDetails?)
}
