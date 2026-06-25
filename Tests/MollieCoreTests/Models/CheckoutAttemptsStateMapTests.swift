import Foundation
import XCTest
@testable import MollieCore

final class CheckoutAttemptsStateMapTests: XCTestCase {
    func test_decode_emptyArray_yieldsEmptyEntries() throws {
        let data = Data("[]".utf8)
        let map = try MollieJSONDecoder().decode(CheckoutAttemptsStateMap.self, from: data)
        XCTAssertTrue(map.entries.isEmpty)
        XCTAssertNil(map["any_token"])
    }

    func test_decode_emptyObject_yieldsEmptyEntries() throws {
        let data = Data("{}".utf8)
        let map = try MollieJSONDecoder().decode(CheckoutAttemptsStateMap.self, from: data)
        XCTAssertTrue(map.entries.isEmpty)
    }

    func test_decode_populatedObject_yieldsEntries() throws {
        let json = """
        {
          "chatt_abc": {
            "session_token": "sess_xyz",
            "status": "open",
            "next_action": { "action_type": "await" },
            "payment_amount": { "amount": "10.00", "currency": "EUR" }
          }
        }
        """
        let map = try MollieJSONDecoder().decode(CheckoutAttemptsStateMap.self, from: Data(json.utf8))
        XCTAssertEqual(map.entries.count, 1)
        XCTAssertEqual(map["chatt_abc"]?.sessionToken, "sess_xyz")
    }

    func test_decode_nonEmptyArray_throws() {
        // A non-empty array would mean the backend changed shape — we explicitly
        // only handle [] as the empty-state synonym, not [...] as a list.
        let data = Data(#"[{"session_token":"sess_x"}]"#.utf8)
        XCTAssertThrowsError(try MollieJSONDecoder().decode(CheckoutAttemptsStateMap.self, from: data))
    }
}
