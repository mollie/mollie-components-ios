import XCTest
@testable import MollieCore

final class NoOpChannelsClientTests: XCTestCase {
    func test_subscribe_yieldsNoEvents_andFinishes() async throws {
        let client = NoOpChannelsClient()
        let stream = try await client.subscribe(to: "any-token")
        var received: [ChannelEvent] = []
        for await event in stream {
            received.append(event)
        }
        XCTAssertTrue(received.isEmpty)
    }

    func test_unsubscribe_isNoOp() async {
        let client = NoOpChannelsClient()
        await client.unsubscribe(from: "any-token")
    }

    func test_disconnect_isNoOp() async {
        let client = NoOpChannelsClient()
        await client.disconnect()
    }
}
