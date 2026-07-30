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

    // T-11: any reflection-based dump of the snapshot (String(reflecting:),
    // dump(_:), a crash reporter auto-mirroring locals) must never emit the
    // cleartext PAN, CVC, cardholder name, or expiry. Mirrors the redacted
    // TokenizeRequest.debugDescription contract.
    func test_debugDescription_doesNotLeakSensitiveFields() {
        let snapshot = CardFormSnapshot(
            cardholderName: "Ada Lovelace",
            cardNumber: "4242424242424242",
            expiry: "12/30",
            cvc: "123"
        )

        let dumped = String(reflecting: snapshot)

        XCTAssertFalse(dumped.contains("4242424242424242"), "PAN must not appear in debug output")
        XCTAssertFalse(dumped.contains("123"), "CVC must not appear in debug output")
        XCTAssertFalse(dumped.contains("Ada Lovelace"), "Cardholder name must not appear in debug output")
        XCTAssertFalse(dumped.contains("12/30"), "Expiry must not appear in debug output")
        XCTAssertEqual(snapshot.debugDescription, "CardFormSnapshot(redacted)")
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
