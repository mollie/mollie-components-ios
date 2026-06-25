import Foundation

/// Events emitted by a `MollieChannelsClient` while a session is in flight.
///
/// Equatable is synthesized: all associated value types (`SessionResponse`,
/// `URL`, `ProblemDetails?`) conform to Equatable. `SessionResponse` Equatable
/// is backed by `AnyCodable`'s NSObject-bridging Equatable (see AnyCodable.swift).
/// Made public so MollieChannelsClient (public for demo target access) can reference it.
/// Will be re-evaluated when MollieComponents umbrella ships in Phase 4.
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
    case sessionCompleted(SessionResponse)
    case sessionFailed(ProblemDetails?)
}
