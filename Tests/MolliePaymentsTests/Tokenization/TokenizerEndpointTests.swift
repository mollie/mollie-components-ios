import Foundation
import MollieCore
import XCTest
@testable import MolliePayments

final class TokenizerEndpointTests: XCTestCase {
    func test_tokenize_attachesTokenisationAgentHeader() throws {
        let endpoint = TokenizerEndpoint.tokenize(
            CardSubmissionData(
                cardholderName: "Jane Doe",
                cardNumber: "4242424242424242",
                expiryMonth: 12,
                expiryYear: 2030,
                cvc: "123"
            ),
            profileToken: "pfl_test",
            testmode: true
        )

        let encoded = try XCTUnwrap(endpoint.headers["Tokenisation-Agent"])
        let decoded = try XCTUnwrap(Data(base64Encoded: encoded))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: decoded) as? [String: Any])

        XCTAssertEqual(json["product"] as? String, "Mollie-iOS-SDK")
        XCTAssertEqual(json["productLocation"] as? String, "card")
        let productVersion = try XCTUnwrap(json["productVersion"] as? String)
        XCTAssertFalse(productVersion.isEmpty)
        XCTAssertEqual(productVersion, MollieSDKVersion)
        XCTAssertTrue(json["parentUri"] is NSNull)
        XCTAssertTrue(json["sourceUri"] is NSNull)
        XCTAssertTrue(json["plugin"] is NSNull)
        XCTAssertTrue(json["pluginVersion"] is NSNull)
    }
}
