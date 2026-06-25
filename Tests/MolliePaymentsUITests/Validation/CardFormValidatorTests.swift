import XCTest
@testable import MolliePaymentsUI

final class CardFormValidatorTests: XCTestCase {
    private func makeSnapshot(
        name: String = "Ada Lovelace",
        pan: String = "4242424242424242",
        expiry: String = "12/40",
        cvc: String = "123"
    ) -> CardFormSnapshot {
        CardFormSnapshot(cardholderName: name, cardNumber: pan, expiry: expiry, cvc: cvc)
    }

    func test_validSnapshot_passes() {
        XCTAssertNil(CardFormValidator.validate(snapshot: makeSnapshot()))
    }

    func test_acceptsPANWithSpaces() {
        // Form lets users type whatever; validator strips whitespace before
        // applying the length / Luhn check.
        let snapshot = makeSnapshot(pan: "4242 4242 4242 4242")
        XCTAssertNil(CardFormValidator.validate(snapshot: snapshot))
    }

    func test_acceptsPANWithHyphens_paste() {
        // Clipboard pastes from card-printed receipts often arrive with
        // hyphen separators. Validator must normalise to a digit run
        // before length + Luhn, otherwise a legit paste fails.
        let snapshot = makeSnapshot(pan: "4242-4242-4242-4242")
        XCTAssertNil(CardFormValidator.validate(snapshot: snapshot))
    }

    func test_acceptsPANWithNBSP_paste() {
        // Non-breaking space arrives from `Cmd+C` on certain web tables;
        // it isn't caught by `.isWhitespace` everywhere. ASCII-digit-only
        // filter drops it.
        let snapshot = makeSnapshot(pan: "4242\u{00A0}4242\u{00A0}4242\u{00A0}4242")
        XCTAssertNil(CardFormValidator.validate(snapshot: snapshot))
    }

    func test_rejectsArabicIndicDigitPAN() {
        // Arabic-Indic digits satisfy `Character.isNumber` but the
        // tokeniser rejects them. ASCII-only normalisation strips the
        // entire string to empty, which then trips `panTooShort`.
        let snapshot =
            makeSnapshot(
                pan: "\u{0664}\u{0662}\u{0664}\u{0662}\u{0664}\u{0662}\u{0664}\u{0662}\u{0664}\u{0662}\u{0664}\u{0662}\u{0664}\u{0662}\u{0664}\u{0662}"
            )
        XCTAssertEqual(
            CardFormValidator.validate(snapshot: snapshot),
            .panTooShort
        )
    }

    // MARK: - Cardholder

    func test_emptyName_fails() {
        XCTAssertEqual(
            CardFormValidator.validate(snapshot: makeSnapshot(name: "")),
            .missingCardholder
        )
    }

    func test_whitespaceOnlyName_fails() {
        // Regression target: a single space shouldn't satisfy the cardholder
        // requirement when the merchant later relies on the name being a
        // real string.
        XCTAssertEqual(
            CardFormValidator.validate(snapshot: makeSnapshot(name: "   ")),
            .missingCardholder
        )
    }

    // MARK: - PAN

    func test_panTooShort_fails() {
        XCTAssertEqual(
            CardFormValidator.validate(snapshot: makeSnapshot(pan: "424242424242")),
            .panTooShort
        )
    }

    func test_panTooLong_fails() {
        XCTAssertEqual(
            CardFormValidator.validate(snapshot: makeSnapshot(pan: "42424242424242424242")),
            .panTooLong
        )
    }

    func test_panFailsLuhn_fails() {
        // Right length, fails Luhn.
        XCTAssertEqual(
            CardFormValidator.validate(snapshot: makeSnapshot(pan: "4242424242424243")),
            .panFailsLuhn
        )
    }

    // MARK: - Expiry

    func test_malformedExpiry_fails() {
        XCTAssertEqual(
            CardFormValidator.validate(snapshot: makeSnapshot(expiry: "1240")),
            .expiry(.malformed)
        )
    }

    // MARK: - CVC

    func test_cvc3Digits_passes() {
        XCTAssertEqual(
            CardFormValidator.validate(snapshot: makeSnapshot(cvc: "123")),
            nil
        )
    }

    func test_cvc4Digits_passes() {
        XCTAssertEqual(
            CardFormValidator.validate(snapshot: makeSnapshot(cvc: "1234")),
            nil
        )
    }

    func test_cvc2Digits_fails() {
        XCTAssertEqual(
            CardFormValidator.validate(snapshot: makeSnapshot(cvc: "12")),
            .cvcWrongLength
        )
    }

    func test_cvc5Digits_fails() {
        XCTAssertEqual(
            CardFormValidator.validate(snapshot: makeSnapshot(cvc: "12345")),
            .cvcWrongLength
        )
    }

    func test_cvcNonDigits_fails() {
        XCTAssertEqual(
            CardFormValidator.validate(snapshot: makeSnapshot(cvc: "12X")),
            .cvcWrongLength
        )
    }

    // MARK: - User messages

    func test_userMessages_areSpecificEnoughToAct() {
        // Regression target: error messages must point at the field that
        // needs fixing. A generic "invalid input" would be a UX regression.
        XCTAssertTrue(CardFormValidator.ValidationError.missingCardholder.userMessage.lowercased().contains("name"))
        XCTAssertTrue(CardFormValidator.ValidationError.panTooShort.userMessage.lowercased().contains("card number"))
        XCTAssertTrue(CardFormValidator.ValidationError.cvcWrongLength.userMessage.lowercased().contains("cvc"))
        XCTAssertTrue(CardFormValidator.ValidationError.expiry(.malformed).userMessage.lowercased().contains("expiry"))
    }
}
