import XCTest
@testable import MolliePaymentsUI

final class LuhnTests: XCTestCase {
    // MARK: - Valid PANs

    func test_visaTestPAN_passes() {
        // Standard Visa test card from PCI test suites.
        XCTAssertTrue(Luhn.isValid("4242424242424242"))
    }

    func test_mastercardTestPAN_passes() {
        XCTAssertTrue(Luhn.isValid("5555555555554444"))
    }

    func test_amexTestPAN_passes() {
        XCTAssertTrue(Luhn.isValid("378282246310005"))
    }

    func test_discoverTestPAN_passes() {
        XCTAssertTrue(Luhn.isValid("6011111111111117"))
    }

    // MARK: - Invalid PANs

    func test_singleDigitFlip_fails() {
        // Off-by-one against the Visa test PAN — caught by Luhn.
        XCTAssertFalse(Luhn.isValid("4242424242424243"))
    }

    func test_isValid_allZeros_returnsFalse() {
        // Defensive: an all-zero PAN is arithmetically valid under Luhn
        // (sum is zero, zero is divisible by ten) but no real issuer ships
        // an all-zero PAN. The validator now rejects it up front so a
        // bug that hands us a memset-ed buffer cannot false-positive past
        // the length + Luhn gate.
        XCTAssertFalse(Luhn.isValid(""))
        XCTAssertFalse(Luhn.isValid("0"))
        XCTAssertFalse(Luhn.isValid("00"))
        XCTAssertFalse(Luhn.isValid("0000000000000"))
        XCTAssertFalse(Luhn.isValid("00000000000000000000"))
    }

    // MARK: - Defensive / non-digit

    func test_emptyString_fails() {
        XCTAssertFalse(Luhn.isValid(""))
    }

    func test_nonDigitCharacters_fail() {
        // A PAN with embedded letters or whitespace shouldn't pass — the
        // caller strips formatting before calling, but the validator
        // should never accept garbage.
        XCTAssertFalse(Luhn.isValid("4242 4242 4242 4242"))
        XCTAssertFalse(Luhn.isValid("4242X424242424242"))
    }

    func test_fullWidthDigits_fail() {
        // `Character.isNumber` accepts Unicode digit classes (Arabic, etc.)
        // but `Character.isASCII && .isNumber` rejects them. Tokenisation
        // expects plain ASCII digits; non-ASCII numerics would surprise the
        // server-side parser.
        XCTAssertFalse(Luhn
            .isValid(
                "\u{ff14}\u{ff12}\u{ff14}\u{ff12}\u{ff14}\u{ff12}\u{ff14}\u{ff12}\u{ff14}\u{ff12}\u{ff14}\u{ff12}\u{ff14}\u{ff12}\u{ff14}\u{ff12}"
            ))
    }
}
