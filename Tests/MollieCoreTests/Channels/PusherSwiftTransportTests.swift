import XCTest
@testable import MollieCore

/// Verifies the `PusherDelegate.failedToSubscribeToChannel` mapping preserves
/// the diagnostic detail (HTTP status + NSError domain/code/description) in the
/// `.failedToSubscribe(reason:)` signal, so a production subscription failure
/// has a logged cause instead of vanishing behind a silently-finished stream.
final class PusherSwiftTransportTests: XCTestCase {
    private func makeTransport() -> PusherSwiftTransport {
        // No network happens until `connect()`; constructing the wrapper only
        // stands up the delegate plumbing we exercise here.
        PusherSwiftTransport(credentials: PusherCredentials(appKey: "pk_test", cluster: "eu"))
    }

    func test_failedToSubscribe_carriesHTTPStatusAndError() throws {
        let transport = makeTransport()
        var captured: PusherTransportSignal?
        transport.onSignal = { captured = $0 }

        let url = try XCTUnwrap(URL(string: "https://ws.pusher.com/subscribe"))
        let response = HTTPURLResponse(url: url, statusCode: 403, httpVersion: nil, headerFields: nil)
        let error = NSError(
            domain: "PusherSwift",
            code: 42,
            userInfo: [NSLocalizedDescriptionKey: "auth denied"]
        )

        transport.failedToSubscribeToChannel(
            name: "px_sessions_app_session_sess_abc123",
            response: response,
            data: nil,
            error: error
        )

        guard case let .failedToSubscribe(channelName, reason) = captured else {
            return XCTFail("Expected .failedToSubscribe, got \(String(describing: captured))")
        }
        XCTAssertEqual(channelName, "px_sessions_app_session_sess_abc123")
        let reasonText = try XCTUnwrap(reason)
        XCTAssertTrue(reasonText.contains("http=403"), "reason should carry HTTP status: \(reasonText)")
        XCTAssertTrue(reasonText.contains("#42"), "reason should carry error code: \(reasonText)")
        XCTAssertTrue(reasonText.contains("auth denied"), "reason should carry description: \(reasonText)")
    }

    func test_failedToSubscribe_noDetail_yieldsNilReason() {
        let transport = makeTransport()
        var captured: PusherTransportSignal?
        transport.onSignal = { captured = $0 }

        transport.failedToSubscribeToChannel(name: "any", response: nil, data: nil, error: nil)

        guard case let .failedToSubscribe(_, reason) = captured else {
            return XCTFail("Expected .failedToSubscribe, got \(String(describing: captured))")
        }
        XCTAssertNil(reason, "no response/error → nil reason (not an empty string)")
    }
}
