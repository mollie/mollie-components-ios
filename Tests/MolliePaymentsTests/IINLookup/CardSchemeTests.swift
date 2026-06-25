import Foundation
import XCTest
@testable import MolliePayments

final class CardSchemeTests: XCTestCase {
    func test_decode_knownSchemes_mapToCases() throws {
        let cases: [(String, CardScheme)] = [
            ("visa", .visa),
            ("mastercard", .mastercard),
            ("amex", .amex),
            ("maestro", .maestro),
            ("discover", .discover),
            ("dinersClub", .dinersClub),
            ("jcb", .jcb),
            ("unionPay", .unionPay),
            ("cartesBancaires", .cartesBancaires),
        ]
        let decoder = JSONDecoder()
        for (raw, expected) in cases {
            let json = Data("\"\(raw)\"".utf8)
            let decoded = try decoder.decode(CardScheme.self, from: json)
            XCTAssertEqual(decoded, expected, "Expected \(raw) to decode to \(expected)")
        }
    }

    func test_decode_unknown_fallsBackToOther() throws {
        let json = Data("\"futurecard\"".utf8)
        let decoded = try JSONDecoder().decode(CardScheme.self, from: json)
        XCTAssertEqual(decoded, .other("futurecard"))
    }

    func test_equatable_otherSameString_isEqual() {
        XCTAssertEqual(CardScheme.other("foo"), CardScheme.other("foo"))
    }

    func test_equatable_otherDifferentString_isNotEqual() {
        XCTAssertNotEqual(CardScheme.other("foo"), CardScheme.other("bar"))
    }
}
