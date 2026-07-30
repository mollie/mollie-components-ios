import Foundation

/// Lifecycle / error signals surfaced by a `PusherTransport` to its observer.
///
/// Deliberately narrower than `PusherDelegate`: we only model what
/// `PusherChannelsClient` acts on. Transient `connecting` / `reconnecting`
/// states are NOT represented — `autoReconnect` is on by default and the
/// library owns recovery, so the client must not treat them as fatal.
public enum PusherTransportSignal: Sendable {
    /// A hard error from the connection (`PusherDelegate.receivedError`). The
    /// `code` is the WebSocket close code; 4000–4099 are fatal per the Pusher
    /// protocol (the client finishes the stream so the consumer fails over to
    /// polling).
    case error(code: Int?)
    /// Subscription to the session channel failed
    /// (`PusherDelegate.failedToSubscribeToChannel`). Always fatal. `reason`
    /// carries the HTTP status / Pusher error code / description the library
    /// supplied (nil when it gave none), so the cause crosses the transport
    /// boundary and is logged before the client fails over to polling instead
    /// of vanishing behind a silently-finished stream.
    case failedToSubscribe(channelName: String, reason: String?)
    /// PusherSwift connection state transition (informational — never fatal).
    case connectionStateChanged(fromState: String, toState: String)
    /// Channel subscription confirmed by PusherSwift (informational — never fatal).
    case subscriptionSucceeded(channelName: String)
}

/// The exact slice of PusherSwift that `PusherChannelsClient` drives, behind a
/// protocol so the client is unit-testable without a live socket. The real
/// implementation (`PusherSwiftTransport`) wraps `Pusher`; tests inject a fake.
///
/// Callbacks may fire on an arbitrary queue; the client hops them into its
/// AsyncStream with explicit isolation. `@unchecked Sendable` because the
/// concrete wrapper holds a `Pusher` reference type whose Sendability the
/// compiler can't prove — access is serialized by the client's lock.
public protocol PusherTransport: AnyObject, Sendable {
    /// Raw frames for the bound event (`session_changed`). The `String` is the
    /// PusherEvent `data` payload — JSON the client decodes itself.
    var onEvent: (@Sendable (String) -> Void)? { get set }
    /// Lifecycle / error signals the client maps to fatal stream-finish.
    var onSignal: (@Sendable (PusherTransportSignal) -> Void)? { get set }

    /// Open the connection, subscribe to `channelName`, and bind `eventName`.
    func connectAndSubscribe(channelName: String, eventName: String)
    func unsubscribe(channelName: String)
    func disconnect()
}
