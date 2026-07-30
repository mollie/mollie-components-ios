import XCTest
@testable import MollieCore

final class PusherChannelsClientTests: XCTestCase {
    // MARK: - Fake transport

    /// Records lifecycle calls and lets tests drive the `onEvent` / `onSignal`
    /// closures the client installs — standing in for a live socket.
    private final class FakeTransport: PusherTransport, @unchecked Sendable {
        var onEvent: (@Sendable (String) -> Void)?
        var onSignal: (@Sendable (PusherTransportSignal) -> Void)?

        private(set) var subscribedChannel: String?
        private(set) var boundEvent: String?
        private(set) var unsubscribedChannel: String?
        private(set) var disconnectCount = 0

        func connectAndSubscribe(channelName: String, eventName: String) {
            subscribedChannel = channelName
            boundEvent = eventName
        }

        func unsubscribe(channelName: String) {
            unsubscribedChannel = channelName
        }

        func disconnect() {
            disconnectCount += 1
        }
    }

    private func makeClient(
        credentials: PusherCredentials = .init(appKey: "k", cluster: "eu"),
        channelName: String = "px_sessions_app_session_sess_abc123",
        eventName: String = "session_changed",
        transport: FakeTransport
    ) -> PusherChannelsClient {
        PusherChannelsClient(
            credentials: credentials,
            channelName: channelName,
            eventName: eventName,
            makeTransport: { _ in transport }
        )
    }

    // MARK: - Channel naming

    func test_subscribe_usesChannelAndEventSuppliedByCaller() async throws {
        // The channel and event are no longer derived from the
        // session token by a hardcoded prefix — they come verbatim from the
        // token's `PusherConfiguration`, which the caller (DI site) passes
        // into the initializer. Pin that the transport receives exactly
        // what was configured, not a recomputed name.
        let transport = FakeTransport()
        let client = makeClient(
            channelName: "px_sessions_app_session_sess_xyz",
            eventName: "session_changed",
            transport: transport
        )

        _ = try await client.subscribe(to: "sess_xyz")

        XCTAssertEqual(transport.subscribedChannel, "px_sessions_app_session_sess_xyz")
        XCTAssertEqual(transport.boundEvent, "session_changed")
    }

    func test_subscribe_subscribesToExactChannelAndBindsSessionChanged() async throws {
        let transport = FakeTransport()
        let client = makeClient(transport: transport)

        _ = try await client.subscribe(to: "sess_abc123")

        XCTAssertEqual(transport.subscribedChannel, "px_sessions_app_session_sess_abc123")
        XCTAssertEqual(transport.boundEvent, "session_changed")
    }

    // MARK: - Doorbell emission

    func test_subscribe_yieldsDoorbell_onSessionChangedFrame() async throws {
        let transport = FakeTransport()
        let client = makeClient(transport: transport)

        let stream = try await client.subscribe(to: "sess_abc123")

        // Deliver one frame, then finish so the for-await terminates.
        transport.onEvent?(#"{"session_token":"sess_abc123","event_id":42}"#)
        transport.onSignal?(.failedToSubscribe(channelName: "px_sessions_app_session_sess_abc123", reason: nil))

        var received: [ChannelDoorbell] = []
        for await doorbell in stream {
            received.append(doorbell)
        }

        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received.first?.eventId, 42)
    }

    func test_subscribe_yieldsDoorbellWithNilEventId_whenPayloadHasNoEventId() async throws {
        let transport = FakeTransport()
        let client = makeClient(transport: transport)

        let stream = try await client.subscribe(to: "sess_abc123")
        transport.onEvent?(#"{"session_token":"sess_abc123"}"#)
        transport.onSignal?(.failedToSubscribe(channelName: "any", reason: nil))

        var received: [ChannelDoorbell] = []
        for await doorbell in stream {
            received.append(doorbell)
        }

        XCTAssertEqual(received.count, 1)
        XCTAssertNil(received.first?.eventId)
    }

    // MARK: - Fatal signals finish the stream

    func test_subscribe_finishesStream_onFatalCloseCode() async throws {
        let transport = FakeTransport()
        let client = makeClient(transport: transport)

        let stream = try await client.subscribe(to: "sess_abc123")
        transport.onSignal?(.error(code: 4001))

        var received: [ChannelDoorbell] = []
        for await doorbell in stream {
            received.append(doorbell)
        }

        XCTAssertTrue(received.isEmpty)
    }

    func test_subscribe_finishesStream_onFailedToSubscribe() async throws {
        let transport = FakeTransport()
        let client = makeClient(transport: transport)

        let stream = try await client.subscribe(to: "sess_abc123")
        transport.onSignal?(.failedToSubscribe(channelName: "px_sessions_app_session_sess_abc123", reason: nil))

        var received: [ChannelDoorbell] = []
        for await doorbell in stream {
            received.append(doorbell)
        }

        XCTAssertTrue(received.isEmpty)
    }

    func test_nonFatalCloseCode_doesNotFinishStream() async throws {
        let transport = FakeTransport()
        let client = makeClient(transport: transport)

        let stream = try await client.subscribe(to: "sess_abc123")

        // A non-4000–4099 error must NOT finish the stream; the library owns
        // reconnect. A subsequent frame should still arrive. We finish via a
        // genuine fatal afterwards so the for-await terminates.
        transport.onSignal?(.error(code: 1006))
        transport.onEvent?(#"{"event_id":7}"#)
        transport.onSignal?(.failedToSubscribe(channelName: "any", reason: nil))

        var received: [ChannelDoorbell] = []
        for await doorbell in stream {
            received.append(doorbell)
        }

        XCTAssertEqual(received.map(\.eventId), [7])
    }

    // MARK: - Termination cleanup

    func test_streamTermination_unsubscribesAndDisconnects() async throws {
        let transport = FakeTransport()
        let client = makeClient(transport: transport)

        let stream = try await client.subscribe(to: "sess_abc123")
        // Finish the stream → onTermination should tear the transport down.
        transport.onSignal?(.failedToSubscribe(channelName: "any", reason: nil))
        for await _ in stream {}

        // onTermination runs asynchronously after the stream finishes; give it
        // a turn to fire.
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(transport.unsubscribedChannel, "px_sessions_app_session_sess_abc123")
        XCTAssertGreaterThanOrEqual(transport.disconnectCount, 1)
    }

    // MARK: - Fatal close-code classification

    func test_isFatalCloseCode() {
        XCTAssertTrue(PusherChannelsClient.isFatalCloseCode(4000))
        XCTAssertTrue(PusherChannelsClient.isFatalCloseCode(4099))
        XCTAssertFalse(PusherChannelsClient.isFatalCloseCode(3999))
        XCTAssertFalse(PusherChannelsClient.isFatalCloseCode(4100))
        XCTAssertFalse(PusherChannelsClient.isFatalCloseCode(1006))
        XCTAssertFalse(PusherChannelsClient.isFatalCloseCode(nil))
    }
}
