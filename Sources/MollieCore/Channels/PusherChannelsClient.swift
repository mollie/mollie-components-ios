import Foundation

/// Real-time `MollieChannelsClient` backed by a `PusherTransport`. Subscribes
/// to the session's PUBLIC channel and turns each `session_changed` frame into
/// a `ChannelDoorbell` tick. The payload is a doorbell, not data — only an
/// optional `event_id` rides along; the consumer owns the re-fetch + diff.
///
/// Channel name and event are supplied by the token's `PusherConfiguration` —
/// the Sessions Service is the single source of truth for both, matching its
/// own emitter.
///
/// Lifecycle (PusherSwift's 5-state model):
///  - A `receivedError` with a 4000–4099 close code, or `failedToSubscribe`,
///    is FATAL → the stream finishes so `SessionEventConsumer` fails over to
///    HTTP polling.
///  - Transient `connecting` / `reconnecting` are left to the library
///    (`autoReconnect` is on) — they are never surfaced as fatal here.
///  - On `continuation.onTermination` (consumer cancelled / stream finished)
///    the client unsubscribes + disconnects so no socket leaks.
///
/// `@unchecked Sendable`: the live continuation is mutated from transport
/// callbacks arriving on an arbitrary queue; access is serialized by `lock`.
public final class PusherChannelsClient: MollieChannelsClient, @unchecked Sendable {
    private let credentials: PusherCredentials
    private let channelName: String
    private let eventName: String
    private let makeTransport: @Sendable (PusherCredentials) -> PusherTransport

    private let lock = NSLock()
    private var transport: PusherTransport?
    private var continuation: AsyncStream<ChannelDoorbell>.Continuation?

    /// - Parameters:
    ///   - credentials: PUBLIC app key + cluster (see `PusherCredentials`).
    ///   - channelName: fully-resolved channel name from the token's
    ///     `PusherConfiguration`.
    ///   - eventName: event name to bind, from the token's `PusherConfiguration`.
    ///   - makeTransport: factory for the underlying transport, seam for tests.
    ///     Defaults to the real PusherSwift-backed transport.
    public init(
        credentials: PusherCredentials,
        channelName: String,
        eventName: String,
        makeTransport: @escaping @Sendable (PusherCredentials)
            -> PusherTransport = { PusherSwiftTransport(credentials: $0) }
    ) {
        self.credentials = credentials
        self.channelName = channelName
        self.eventName = eventName
        self.makeTransport = makeTransport
    }

    public func subscribe(to sessionToken: String) async throws -> AsyncStream<ChannelDoorbell> {
        // Local copy so the [weak self] onTermination closure can tear down the
        // exact channel even if `self` has been released by then.
        let channelName = channelName
        let transport = makeTransport(credentials)

        MollieLogger.log(
            "Pusher",
            "subscribing channel=\(channelName) event=\(eventName) cluster=\(credentials.cluster) token=…\(String(sessionToken.suffix(4)))"
        )

        return AsyncStream { continuation in
            lock.lock()
            self.transport = transport
            self.continuation = continuation
            lock.unlock()

            // Frames → doorbells. Decode defensively: a frame that doesn't
            // parse is dropped, not fatal (a malformed doorbell shouldn't kill
            // the live channel; the watchdog/poll fallback still covers us).
            transport.onEvent = { [weak self] raw in
                guard let self else { return }
                let eventId = Self.decodeEventId(from: raw)
                MollieLogger.log("Pusher", "doorbell received event_id=\(eventId.map(String.init) ?? "–")")
                yield(ChannelDoorbell(eventId: eventId))
            }

            // Fatal signals → finish the stream so the consumer fails over.
            transport.onSignal = { [weak self] signal in
                guard let self else { return }
                switch signal {
                case let .connectionStateChanged(fromState, toState):
                    MollieLogger.log("Pusher", "connection \(fromState) → \(toState)")
                    if toState == "connected" {}
                case let .subscriptionSucceeded(channelName):
                    MollieLogger.log("Pusher", "subscription succeeded channel=\(channelName) — real-time active")
                case let .error(code):
                    let fatal = Self.isFatalCloseCode(code)
                    MollieLogger.log("Pusher", "error code=\(code.map(String.init) ?? "nil") fatal=\(fatal)")
                    if fatal {
                        finish()
                    }
                case let .failedToSubscribe(channelName, reason):
                    MollieLogger.log(
                        "Pusher",
                        "failed to subscribe channel=\(channelName) reason=\(reason ?? "–") — failing over to polling"
                    )
                    finish()
                }
            }

            continuation.onTermination = { [weak self] _ in
                self?.teardown(channelName: channelName)
            }

            transport.connectAndSubscribe(channelName: channelName, eventName: eventName)
        }
    }

    public func unsubscribe(from _: String) async {
        teardown(channelName: channelName)
    }

    public func disconnect() async {
        currentTransport()?.disconnect()
    }

    // MARK: - Private

    /// Snapshot the live transport under the lock. Kept non-async so the lock
    /// is never taken from an async context (NSLock is unavailable there).
    private func currentTransport() -> PusherTransport? {
        lock.lock()
        defer { lock.unlock() }
        return transport
    }

    private func yield(_ doorbell: ChannelDoorbell) {
        lock.lock()
        let continuation = continuation
        lock.unlock()
        continuation?.yield(doorbell)
    }

    private func finish() {
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.finish()
    }

    private func teardown(channelName: String) {
        lock.lock()
        let transport = transport
        self.transport = nil
        continuation = nil
        lock.unlock()
        transport?.unsubscribe(channelName: channelName)
        transport?.disconnect()
        // Only log/emit when there was a live transport — a teardown on an
        // already-clean client (double unsubscribe, late onTermination) is a
        // no-op and must not produce a spurious disconnect breadcrumb.
        if transport != nil {
            MollieLogger.log("Pusher", "disconnected")
        }
    }

    /// Pusher protocol: close codes 4000–4099 are fatal (must not reconnect).
    /// A nil code is treated as non-fatal — let the library decide.
    static func isFatalCloseCode(_ code: Int?) -> Bool {
        guard let code else { return false }
        return (4000 ... 4099).contains(code)
    }

    /// Decode the doorbell `event_id` from the raw `session_changed` payload
    /// (`{"session_token": "...", "event_id": 123}`). Returns nil when absent
    /// or unparseable — `event_id` is informational only.
    static func decodeEventId(from raw: String) -> Int? {
        guard let data = raw.data(using: .utf8) else { return nil }
        return (try? JSONDecoder().decode(DoorbellPayload.self, from: data))?.eventId
    }
}

/// Wire shape of the `session_changed` doorbell payload. Only `event_id` is
/// read — `session_token` is implied by the channel we subscribed to.
private struct DoorbellPayload: Decodable {
    let eventId: Int?

    enum CodingKeys: String, CodingKey {
        case eventId = "event_id"
    }
}
