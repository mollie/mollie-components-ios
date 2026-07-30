import XCTest
@testable import MolliePayments

final class CardSubmissionDataTests: XCTestCase {
    func test_equatable_sameFields_isEqual() {
        let lhs = CardSubmissionData(
            cardholderName: "Jane Doe",
            cardNumber: "4242424242424242",
            expiryMonth: 12,
            expiryYear: 2030,
            cvc: "123"
        )
        let rhs = CardSubmissionData(
            cardholderName: "Jane Doe",
            cardNumber: "4242424242424242",
            expiryMonth: 12,
            expiryYear: 2030,
            cvc: "123"
        )

        XCTAssertEqual(lhs, rhs)
    }

    func test_equatable_differentCardNumber_isNotEqual() {
        let lhs = CardSubmissionData(
            cardholderName: "Jane Doe",
            cardNumber: "4242424242424242",
            expiryMonth: 12,
            expiryYear: 2030,
            cvc: "123"
        )
        let rhs = CardSubmissionData(
            cardholderName: "Jane Doe",
            cardNumber: "5555555555554444",
            expiryMonth: 12,
            expiryYear: 2030,
            cvc: "123"
        )

        XCTAssertNotEqual(lhs, rhs)
    }

    // T-11: any reflection-based dump of the struct (String(reflecting:),
    // dump(_:), a crash reporter auto-mirroring locals) must never emit the
    // cleartext PAN, CVC, cardholder name, or expiry. Mirrors the redacted
    // TokenizeRequest.debugDescription contract.
    func test_debugDescription_doesNotLeakSensitiveFields() {
        let data = CardSubmissionData(
            cardholderName: "Jane Doe",
            cardNumber: "4242424242424242",
            expiryMonth: 12,
            expiryYear: 2030,
            cvc: "123"
        )

        let dumped = String(reflecting: data)

        XCTAssertFalse(dumped.contains("4242424242424242"), "PAN must not appear in debug output")
        XCTAssertFalse(dumped.contains("123"), "CVC must not appear in debug output")
        XCTAssertFalse(dumped.contains("Jane Doe"), "Cardholder name must not appear in debug output")
        XCTAssertFalse(dumped.contains("2030"), "Expiry year must not appear in debug output")
        XCTAssertEqual(data.debugDescription, "CardSubmissionData(redacted)")
    }

    // T-10: after zero() the PCI-sensitive card-bearing fields (PAN, CVC) are
    // best-effort cleared. This is "drop the reference," not guaranteed memory
    // scrubbing (Swift String storage is opaque). Mirrors
    // CardFormSnapshot.zero(): non-PCI fields (name, expiry) are preserved.
    func test_zero_clearsSensitiveFields() {
        var data = CardSubmissionData(
            cardholderName: "Jane Doe",
            cardNumber: "4242424242424242",
            expiryMonth: 12,
            expiryYear: 2030,
            cvc: "123"
        )

        data.zero()

        XCTAssertEqual(data.cardNumber, "", "PAN reference must be dropped on zero()")
        XCTAssertEqual(data.cvc, "", "CVC reference must be dropped on zero()")
        XCTAssertEqual(data.cardholderName, "Jane Doe", "Name is not PCI; preserved")
        XCTAssertEqual(data.expiryMonth, 12, "Expiry is not PCI; preserved")
        XCTAssertEqual(data.expiryYear, 2030, "Expiry is not PCI; preserved")
    }

    func test_zero_isIdempotent() {
        var data = CardSubmissionData(
            cardholderName: "Jane Doe",
            cardNumber: "4242424242424242",
            expiryMonth: 12,
            expiryYear: 2030,
            cvc: "123"
        )

        data.zero()
        data.zero()

        XCTAssertEqual(data.cardNumber, "")
        XCTAssertEqual(data.cvc, "")
    }
}
