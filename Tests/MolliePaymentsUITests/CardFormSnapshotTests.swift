import XCTest
@testable import MolliePaymentsUI

final class CardFormSnapshotTests: XCTestCase {
    func test_zero_clearsSensitiveFields() {
        // PCI hygiene: after the host coordinator has tokenised the
        // payload it MUST call `zero()` so the PAN/CVC references drop
        // off the snapshot. Non-sensitive fields (name, expiry) are
        // intentionally preserved — they're not in PCI scope and the
        // host may still want to surface them in a receipt.
        var snapshot = CardFormSnapshot(
            cardholderName: "Ada Lovelace",
            cardNumber: "4242424242424242",
            expiry: "12/30",
            cvc: "123"
        )
        snapshot.zero()
        XCTAssertEqual(snapshot.cardNumber, "", "PAN reference must be dropped on zero()")
        XCTAssertEqual(snapshot.cvc, "", "CVC reference must be dropped on zero()")
        XCTAssertEqual(snapshot.cardholderName, "Ada Lovelace", "Name is not PCI; preserved")
        XCTAssertEqual(snapshot.expiry, "12/30", "Expiry is not PCI; preserved")
    }

    func test_zero_isIdempotent() {
        // Calling zero() twice in a row (e.g. defensive cleanup in
        // a `defer` plus an earlier explicit call) must not throw or
        // re-introduce data.
        var snapshot = CardFormSnapshot(
            cardholderName: "Ada Lovelace",
            cardNumber: "4242424242424242",
            expiry: "12/30",
            cvc: "123"
        )
        snapshot.zero()
        snapshot.zero()
        XCTAssertEqual(snapshot.cardNumber, "")
        XCTAssertEqual(snapshot.cvc, "")
    }
}
