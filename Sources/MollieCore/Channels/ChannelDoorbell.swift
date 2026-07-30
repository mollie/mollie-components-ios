/// A "doorbell" tick emitted by a `MollieChannelsClient` whenever the server
/// signals that a session's state may have changed.
///
/// The Pusher payload is intentionally a doorbell, not data: it carries no
/// session state, only an optional `eventId` (the Pusher `SessionEvent` id,
/// informational only — dedup is keyed off `nextAction.eventId` from the
/// re-fetched checkout-attempts response, not this value). On each tick the
/// consumer re-fetches `GET /checkout-attempts/` and diffs per attempt.
/// Made public so MollieChannelsClient (public for demo target access) can
/// reference it. Will be re-evaluated once the `MollieComponents` umbrella
/// target ships.
public struct ChannelDoorbell: Sendable {
    /// The Pusher `SessionEvent` id, if present. Informational only.
    public let eventId: Int?

    public init(eventId: Int? = nil) {
        self.eventId = eventId
    }
}
