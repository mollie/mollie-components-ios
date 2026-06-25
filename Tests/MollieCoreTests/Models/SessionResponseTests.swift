import XCTest
@testable import MollieCore

final class SessionResponseTests: XCTestCase {
    private func decode(_ json: String) throws -> SessionResponse {
        let data = Data(json.utf8)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(SessionResponse.self, from: data)
    }

    private let happyPathJSON = """
    {
        "session_token": "sess_abc123",
        "status": "open",
        "next_action": {
            "action_type": "await",
            "event_id": 42
        },
        "payment_amount": {
            "amount": "10.00",
            "currency": "EUR"
        }
    }
    """

    func test_decode_happyPath() throws {
        let response = try decode(happyPathJSON)
        XCTAssertEqual(response.sessionToken, "sess_abc123")
        XCTAssertEqual(response.status, .known(.open))
        XCTAssertEqual(response.nextAction.actionType, .known(.awaiting))
        XCTAssertEqual(response.nextAction.eventId, 42)
        XCTAssertEqual(response.paymentAmount.value, "10.00")
        XCTAssertEqual(response.paymentAmount.currency, "EUR")
        XCTAssertNil(response.remainingAmount)
        XCTAssertNil(response.paymentMethodDetails)
    }

    func test_unknownStatus_decodesAsUnknown_doesNotThrow() throws {
        let json = """
        {
            "session_token": "sess_abc123",
            "status": "pending",
            "next_action": { "action_type": "none" },
            "payment_amount": { "amount": "5.00", "currency": "EUR" }
        }
        """
        let response = try decode(json)
        XCTAssertEqual(response.status, .unknown("pending"))
    }

    func test_unknownActionType_decodesAsUnknown_doesNotThrow() throws {
        let json = """
        {
            "session_token": "sess_abc123",
            "status": "open",
            "next_action": { "action_type": "brandNewFutureAction" },
            "payment_amount": { "amount": "5.00", "currency": "EUR" }
        }
        """
        let response = try decode(json)
        XCTAssertEqual(response.nextAction.actionType, .unknown("brandNewFutureAction"))
    }

    func test_nextActionParams_withMixedTypes_doesNotThrow() throws {
        let json = """
        {
            "session_token": "sess_abc123",
            "status": "open",
            "next_action": {
                "action_type": "redirect",
                "params": {
                    "url": "https://example.com",
                    "timeout": 30,
                    "secure": true
                }
            },
            "payment_amount": { "amount": "5.00", "currency": "EUR" }
        }
        """
        let response = try decode(json)
        XCTAssertNotNil(response.nextAction.params)
    }

    func test_remainingAmount_presentInJSON_decodesCorrectly() throws {
        let json = """
        {
            "session_token": "sess_abc123",
            "status": "open",
            "next_action": { "action_type": "none" },
            "payment_amount": { "amount": "10.00", "currency": "EUR" },
            "remaining_amount": { "amount": "5.00", "currency": "EUR" }
        }
        """
        let response = try decode(json)
        XCTAssertEqual(response.remainingAmount?.value, "5.00")
    }

    func test_paymentMethodDetails_presentInJSON_decodesCorrectly() throws {
        let json = """
        {
            "session_token": "sess_abc123",
            "status": "open",
            "next_action": { "action_type": "none" },
            "payment_amount": { "amount": "10.00", "currency": "EUR" },
            "payment_method_details": {
                "method": "creditcard"
            }
        }
        """
        let response = try decode(json)
        XCTAssertEqual(response.paymentMethodDetails?.method, .known(.creditCard))
    }

    func test_unknownPaymentMethod_decodesAsUnknown() throws {
        let json = """
        {
            "session_token": "sess_abc123",
            "status": "open",
            "next_action": { "action_type": "none" },
            "payment_amount": { "amount": "10.00", "currency": "EUR" },
            "payment_method_details": {
                "method": "futurePaymentMethod"
            }
        }
        """
        let response = try decode(json)
        XCTAssertEqual(response.paymentMethodDetails?.method, .unknown("futurePaymentMethod"))
    }
}
