import Foundation

/// Client-safe Pusher connection parameters, decoded from the `pusherConfiguration`
/// map inside the merchant-forwarded `clientAccessToken`. The Sessions Service is
/// the single source of truth: it emits the PUBLIC app `key`, the `cluster`,
/// the fully-resolved `channel` name, and the `event` name to bind. The Pusher *secret*
/// and app id are never present — a client only needs these four values to subscribe to
/// the public session channel.
public struct PusherConfiguration: Decodable, Equatable, Sendable {
    /// PUBLIC Pusher app key (publishable identifier, not the secret).
    public let key: String
    /// Pusher cluster, e.g. "eu".
    public let cluster: String
    /// Fully-resolved channel name to subscribe to, e.g. `px_sessions_app_session_<sessionToken>`.
    public let channel: String
    /// Event name to bind on the channel, e.g. `session_changed`.
    public let event: String

    public init(key: String, cluster: String, channel: String, event: String) {
        self.key = key
        self.cluster = cluster
        self.channel = channel
        self.event = event
    }
}
