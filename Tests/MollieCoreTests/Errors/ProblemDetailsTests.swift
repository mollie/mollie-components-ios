import XCTest
@testable import MollieCore

final class ProblemDetailsTests: XCTestCase {
    private func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }

    func test_decode_fullPayload_roundTrips() throws {
        let json = """
        {
            "type": "https://docs.mollie.com/errors/session-failed",
            "title": "Session failed",
            "detail": "The card was declined by the issuer.",
            "status": 422,
            "instance": "sess_abc123"
        }
        """
        let problem = try decoder().decode(ProblemDetails.self, from: Data(json.utf8))
        XCTAssertEqual(problem.type, "https://docs.mollie.com/errors/session-failed")
        XCTAssertEqual(problem.title, "Session failed")
        XCTAssertEqual(problem.detail, "The card was declined by the issuer.")
        XCTAssertEqual(problem.status, 422)
        XCTAssertEqual(problem.instance, "sess_abc123")
    }

    func test_decode_partialPayload_nilFieldsAccepted() throws {
        let json = """
        {
            "title": "Session failed",
            "status": 422
        }
        """
        let problem = try decoder().decode(ProblemDetails.self, from: Data(json.utf8))
        XCTAssertNil(problem.type)
        XCTAssertEqual(problem.title, "Session failed")
        XCTAssertNil(problem.detail)
        XCTAssertEqual(problem.status, 422)
        XCTAssertNil(problem.instance)
    }

    func test_decode_emptyObject_allFieldsNil() throws {
        let problem = try decoder().decode(ProblemDetails.self, from: Data("{}".utf8))
        XCTAssertNil(problem.type)
        XCTAssertNil(problem.title)
        XCTAssertNil(problem.detail)
        XCTAssertNil(problem.status)
        XCTAssertNil(problem.instance)
    }

    func test_encode_decodeCycle_isIdentity() throws {
        let original = ProblemDetails(
            type: "https://docs.mollie.com/errors/session-failed",
            title: "Session failed",
            detail: "Card declined.",
            status: 422,
            instance: "sess_abc123"
        )
        let encoded = try JSONEncoder().encode(original)
        let decoded = try decoder().decode(ProblemDetails.self, from: encoded)
        XCTAssertEqual(decoded, original)
    }

    func test_equatable_sameFields_areEqual() {
        let lhs = ProblemDetails(type: "t", title: "ti", detail: "d", status: 1, instance: "i")
        let rhs = ProblemDetails(type: "t", title: "ti", detail: "d", status: 1, instance: "i")
        XCTAssertEqual(lhs, rhs)
    }

    func test_equatable_differentFields_areNotEqual() {
        let lhs = ProblemDetails(type: "t", title: "ti", detail: "d", status: 1, instance: "i")
        let rhs = ProblemDetails(type: "t", title: "ti", detail: "d", status: 2, instance: "i")
        XCTAssertNotEqual(lhs, rhs)
    }
}
