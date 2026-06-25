import XCTest
@testable import MollieCore

final class ChannelEventTests: XCTestCase {
    private func makeSession(token: String, status: SessionStatus = .open) throws -> SessionResponse {
        let json = """
        {
            "session_token": "\(token)",
            "status": "\(status.rawValue)",
            "next_action": { "action_type": "none" },
            "payment_amount": { "amount": "10.00", "currency": "EUR" }
        }
        """
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(SessionResponse.self, from: Data(json.utf8))
    }

    func test_sessionUpdated_equatable() throws {
        let sessionA = try makeSession(token: "sess_a")
        let sessionACopy = try makeSession(token: "sess_a")
        let sessionB = try makeSession(token: "sess_b")
        XCTAssertEqual(ChannelEvent.sessionUpdated(sessionA), .sessionUpdated(sessionACopy))
        XCTAssertNotEqual(ChannelEvent.sessionUpdated(sessionA), .sessionUpdated(sessionB))
    }

    func test_threeDSChallengeReady_equatable() throws {
        let urlA = try XCTUnwrap(URL(string: "https://example.com/3ds/a"))
        let urlB = try XCTUnwrap(URL(string: "https://example.com/3ds/b"))
        XCTAssertEqual(ChannelEvent.threeDSChallengeReady(urlA), .threeDSChallengeReady(urlA))
        XCTAssertNotEqual(ChannelEvent.threeDSChallengeReady(urlA), .threeDSChallengeReady(urlB))
    }

    func test_sessionCompleted_equatable() throws {
        let sessionA = try makeSession(token: "sess_a", status: .completed)
        let sessionACopy = try makeSession(token: "sess_a", status: .completed)
        let sessionB = try makeSession(token: "sess_b", status: .completed)
        XCTAssertEqual(ChannelEvent.sessionCompleted(sessionA), .sessionCompleted(sessionACopy))
        XCTAssertNotEqual(ChannelEvent.sessionCompleted(sessionA), .sessionCompleted(sessionB))
    }

    func test_sessionFailed_equatable() {
        XCTAssertEqual(ChannelEvent.sessionFailed(nil), .sessionFailed(nil))

        let problem = ProblemDetails(type: "t", title: "ti", detail: "d", status: 422, instance: "i")
        let other = ProblemDetails(type: "t", title: "ti", detail: "d", status: 500, instance: "i")
        XCTAssertEqual(ChannelEvent.sessionFailed(problem), .sessionFailed(problem))
        XCTAssertNotEqual(ChannelEvent.sessionFailed(problem), .sessionFailed(other))
        XCTAssertNotEqual(ChannelEvent.sessionFailed(problem), .sessionFailed(nil))
    }
}
