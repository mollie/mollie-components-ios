import Foundation

/// The PUBLIC Pusher app key + cluster the transport connects with. These are
/// publishable values (the Pusher *secret* never lives in the SDK); they
/// identify the app, not authenticate it.
///
/// Sourced entirely from the token's `PusherConfiguration` (see
/// `PusherConfiguration` semantics) — the SDK holds no hardcoded key and
/// never the secret.
public struct PusherCredentials: Sendable, Equatable {
    public let appKey: String
    public let cluster: String

    public init(appKey: String, cluster: String) {
        self.appKey = appKey
        self.cluster = cluster
    }
}
