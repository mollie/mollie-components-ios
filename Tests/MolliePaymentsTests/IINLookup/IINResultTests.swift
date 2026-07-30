import Foundation
import XCTest
@testable import MolliePayments

final class IINResultTests: XCTestCase {
    func test_decode_singleSchemeWireResponse_yieldsOneElementSet() throws {
        let json = Data("""
        {
            "scheme": "visa",
            "cardType": "credit",
            "issuingCountry": "NL"
        }
        """.utf8)

        let decoded = try JSONDecoder().decode(IINResult.self, from: json)

        XCTAssertEqual(decoded.schemes, [.visa])
        XCTAssertEqual(decoded.cardType, .credit)
        XCTAssertEqual(decoded.issuingCountry, "NL")
    }

    func test_decode_missingOptionalFields_defaultsToNil() throws {
        let json = Data("""
        {
            "scheme": "mastercard"
        }
        """.utf8)

        let decoded = try JSONDecoder().decode(IINResult.self, from: json)

        XCTAssertEqual(decoded.schemes, [.mastercard])
        XCTAssertNil(decoded.cardType)
        XCTAssertNil(decoded.issuingCountry)
    }

    func test_encode_roundTrips_singleWireScheme() throws {
        let result = IINResult(schemes: [.visa], cardType: .credit, issuingCountry: "NL")

        let data = try JSONEncoder().encode(result)
        let redecoded = try JSONDecoder().decode(IINResult.self, from: data)

        XCTAssertEqual(redecoded, result)
    }
}
