#if canImport(UIKit)
    import XCTest
    @testable import MolliePaymentsUI

    /// Digit-sanitisation tests for the PAN field. `.numberPad` only hides
    /// letter keys on the on-screen keyboard — hardware keyboards, paste,
    /// and dictation can still inject anything, so the field must filter.
    final class CardNumberTextFieldTests: XCTestCase {
        // MARK: - Pure helper

        func test_digitsOnly_empty_returnsEmpty() {
            XCTAssertEqual(CardNumberTextField.digitsOnly(""), "")
        }

        func test_digitsOnly_allDigits_unchanged() {
            XCTAssertEqual(CardNumberTextField.digitsOnly("4242424242424242"), "4242424242424242")
        }

        func test_digitsOnly_stripsLetters() {
            XCTAssertEqual(CardNumberTextField.digitsOnly("4242abc4242"), "42424242")
        }

        func test_digitsOnly_stripsSpacesAndPunctuation() {
            // Common paste shapes: humans group digits with spaces or
            // dashes when copying a PAN out of an email / receipt.
            XCTAssertEqual(CardNumberTextField.digitsOnly("4242 4242 4242 4242"), "4242424242424242")
            XCTAssertEqual(CardNumberTextField.digitsOnly("4242-4242-4242-4242"), "4242424242424242")
        }

        func test_digitsOnly_stripsArabicIndicDigits() {
            // ASCII-only mirrors the tokeniser's `[0-9]` expectation —
            // non-ASCII numerals pass `Character.isNumber` but would
            // 400 at the network layer.
            XCTAssertEqual(
                CardNumberTextField.digitsOnly("\u{0661}\u{0662}\u{0663}\u{0664}"),
                ""
            )
        }

        // MARK: - Live editing wiring

        @MainActor
        func test_editingChanged_stripsLetters() {
            let field = CardNumberTextField()
            field.text = "4242abc4242"
            field.sendActions(for: .editingChanged)
            XCTAssertEqual(field.text, "42424242")
        }

        @MainActor
        func test_editingChanged_idempotent_noRewriteWhenAllDigits() {
            // No-op path must leave text + caret untouched so mid-string
            // backspace edits don't get clobbered.
            let field = CardNumberTextField()
            field.text = "4242424242424242"
            field.sendActions(for: .editingChanged)
            XCTAssertEqual(field.text, "4242424242424242")
        }

        // MARK: - Brand-aware formatting

        // Static, directly testable: `sendActions(.editingChanged)` doesn't
        // reliably fire target-action in this repo's headless UIKit test
        // harness.

        func test_format_visa16Digit_groupsFourFourFourFour() {
            XCTAssertEqual(
                CardNumberTextField.format("4242424242424242"),
                "4242 4242 4242 4242"
            )
        }

        func test_format_amex15Digit_groupsFourSixFive() {
            // 34/37 prefix -> Amex -> 4-6-5 grouping, 15-digit max.
            XCTAssertEqual(
                CardNumberTextField.format("378282246310005"),
                "3782 822463 10005"
            )
        }

        func test_format_dinersClub14Digit_groupsFourFourFourTwo() {
            // 36 prefix -> Diners Club -> the 4-6-4 special was dropped
            // since it can't represent the
            // 16-19 digit co-badged PANs the shared 19-digit cap now
            // allows through; Diners now groups in 4s like every other
            // non-Amex scheme.
            XCTAssertEqual(
                CardNumberTextField.format("36070000000010"),
                "3607 0000 0000 10"
            )
        }

        func test_format_dinersClub16Digit_preservedNotTruncatedToFourteen() {
            // Real-world 16-digit Diners BIN-36 PAN (co-badged range) must
            // survive the field's cap in full — the bug this fix corrects
            // silently dropped the last two digits, which then failed Luhn
            // with a misleading "check for typos" error.
            XCTAssertEqual(
                CardNumberTextField.format("3670000000000015"),
                "3670 0000 0000 0015"
            )
        }

        func test_format_visa_overLength_truncatesToNineteenDigits() {
            // 20 raw digits typed against a Visa (4-prefix) BIN must hard-cap
            // at 19 digits (the PCI/validator ceiling) rather than grouping
            // the overflow.
            XCTAssertEqual(
                CardNumberTextField.format("4242424242424242123456"),
                "4242 4242 4242 4242 123"
            )
        }

        func test_format_visa19Digit_isPreservedNotTruncated() {
            // A legitimate 19-digit PAN (the top of the 13-19 digit range
            // `CardFormValidator` accepts) must not lose any digits.
            XCTAssertEqual(
                CardNumberTextField.format("4242424242424242123"),
                "4242 4242 4242 4242 123"
            )
        }

        func test_format_amex_overLength_truncatesToFifteenDigits() {
            XCTAssertEqual(
                CardNumberTextField.format("3782822463100059999"),
                "3782 822463 10005"
            )
        }

        func test_format_stripsLettersBeforeGrouping() {
            XCTAssertEqual(
                CardNumberTextField.format("4242abc4242"),
                "4242 4242"
            )
        }

        func test_format_empty_returnsEmpty() {
            XCTAssertEqual(CardNumberTextField.format(""), "")
        }

        func test_format_unknownPrefix_defaultsToFourDigitGrouping() {
            // No known BIN range matches a leading `9` — falls back to the
            // generic 4-4-4-4 grouping / 19-digit cap.
            XCTAssertEqual(
                CardNumberTextField.format("9999999999999999"),
                "9999 9999 9999 9999"
            )
        }
    }
#endif
