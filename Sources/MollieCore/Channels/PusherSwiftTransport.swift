import Foundation
import PusherSwift

/// `PusherTransport` backed by the real PusherSwift `Pusher` client. Wraps the
/// imperative connect/subscribe/bind API and the `@objc PusherDelegate`
/// callbacks into the narrow `PusherTransport` surface `PusherChannelsClient`
/// drives.
///
/// `@unchecked Sendable`: `Pusher` is a reference type the compiler can't prove
/// Sendable; in practice callbacks are funneled straight to the `onEvent` /
/// `onSignal` closures the client installs (which serialize via its own lock).
public final class PusherSwiftTransport: NSObject, PusherTransport, PusherDelegate, @unchecked Sendable {
    public var onEvent: (@Sendable (String) -> Void)?
    public var onSignal: (@Sendable (PusherTransportSignal) -> Void)?

    private let pusher: Pusher

    public init(credentials: PusherCredentials) {
        let options = PusherClientOptions(
            host: .cluster(credentials.cluster),
            useTLS: true
        )
        pusher = Pusher(key: credentials.appKey, options: options)
        super.init()
        pusher.delegate = self
    }

    public func connectAndSubscribe(channelName: String, eventName: String) {
        let channel = pusher.subscribe(channelName)
        channel.bind(eventName: eventName) { [weak self] (event: PusherEvent) in
            // `data` is the raw JSON payload string (or nil for empty frames).
            guard let raw = event.data else { return }
            self?.onEvent?(raw)
        }
        pusher.connect()
    }

    public func unsubscribe(channelName: String) {
        pusher.unsubscribe(channelName)
    }

    public func disconnect() {
        pusher.disconnect()
    }

    // MARK: - PusherDelegate

    /// Hard connection error. Surface the close code so the client can decide
    /// whether 4000–4099 (fatal per the Pusher protocol) ends the stream.
    @objc(receivedError:)
    public func receivedError(error: PusherError) {
        onSignal?(.error(code: error.code))
    }

    @objc
    public func failedToSubscribeToChannel(
        name: String,
        response: URLResponse?,
        data _: String?,
        error: NSError?
    ) {
        // Preserve the diagnostic detail (HTTP status + Pusher error
        // domain/code/description) so a production subscription failure has a
        // logged cause instead of surfacing only as a silently-finished stream.
        let parts = [
            (response as? HTTPURLResponse).map { "http=\($0.statusCode)" },
            error.map { "error=\($0.domain)#\($0.code) \($0.localizedDescription)" },
        ].compactMap { $0 }
        let reason = parts.isEmpty ? nil : parts.joined(separator: " ")
        onSignal?(.failedToSubscribe(channelName: name, reason: reason))
    }

    @objc public func changedConnectionState(from old: ConnectionState, to new: ConnectionState) {
        onSignal?(.connectionStateChanged(fromState: old.stringValue(), toState: new.stringValue()))
    }

    @objc public func subscribedToChannel(name: String) {
        onSignal?(.subscriptionSucceeded(channelName: name))
    }
}
