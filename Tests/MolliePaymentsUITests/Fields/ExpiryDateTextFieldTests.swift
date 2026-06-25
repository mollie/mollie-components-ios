#if canImport(UIKit)
    import XCTest
    @testable import MolliePaymentsUI

    /// Pure-function tests for the expiry auto-formatter. The number-pad
    /// keyboard has no `/` key, so without this helper a user typing four
    /// digits cannot produce the `MM/YY` string the parser requires.
    final class ExpiryDateTextFieldTests: XCTestCase {
        // MARK: - Progressive typing

        func test_format_empty_returnsEmpty() {
            XCTAssertEqual(ExpiryDateTextField.format(""), "")
        }

        func test_format_oneDigit_noSlash() {
            XCTAssertEqual(ExpiryDateTextField.format("1"), "1")
        }

        func test_format_twoDigits_noSlashYet() {
            // Two digits is still the month-only state — slash appears once
            // the user starts typing the year half.
            XCTAssertEqual(ExpiryDateTextField.format("12"), "12")
        }

        func test_format_threeDigits_insertsSlash() {
            XCTAssertEqual(ExpiryDateTextField.format("123"), "12/3")
        }

        func test_format_fourDigits_complete() {
            XCTAssertEqual(ExpiryDateTextField.format("1234"), "12/34")
        }

        func test_format_fiveDigits_truncatedToFour() {
            // Number-pad can still emit a fifth digit if the caret was
            // mid-string; cap at four so the parser doesn't see `MMM/YY`.
            XCTAssertEqual(ExpiryDateTextField.format("12345"), "12/34")
        }

        // MARK: - Idempotency / paste paths

        func test_format_alreadyFormatted_isIdempotent() {
            XCTAssertEqual(ExpiryDateTextField.format("12/30"), "12/30")
        }

        func test_format_pastedWithSpaces_collapsesToCanonical() {
            // Common paste shape from password managers / clipboard helpers.
            XCTAssertEqual(ExpiryDateTextField.format("12 / 30"), "12/30")
        }

        func test_format_pastedWithLetters_stripsThem() {
            // Defence against paste paths that smuggle non-digits in
            // (smart-substitution, dictation auto-correct, etc.).
            XCTAssertEqual(ExpiryDateTextField.format("abc12/30xyz"), "12/30")
        }

        func test_format_pastedRawDigits_addsSlash() {
            // Some merchant prefill paths or password managers serve the
            // expiry as bare digits — formatter normalises them.
            XCTAssertEqual(ExpiryDateTextField.format("1230"), "12/30")
        }

        func test_format_arabicIndicDigits_stripped() {
            // ASCII-only digit filter mirrors `ExpiryParser`'s guard — the
            // parser only accepts ASCII digits, so the formatter should
            // not silently let non-ASCII numerals through and then fail
            // validation downstream.
            XCTAssertEqual(
                ExpiryDateTextField.format("\u{0661}\u{0662}/\u{0662}\u{0667}"),
                ""
            )
        }

        // MARK: - Live editing wiring

        @MainActor
        func test_editingChanged_formatsLiveText() {
            let field = ExpiryDateTextField()
            field.text = "123"
            field.sendActions(for: .editingChanged)
            XCTAssertEqual(
                field.text,
                "12/3",
                "Field must auto-format on `editingChanged` so the user never types the slash"
            )
        }

        @MainActor
        func test_editingChanged_idempotent_noRewriteWhenAlreadyFormatted() {
            // Avoid the caret-to-end jump when nothing needs to change —
            // otherwise mid-string cursor edits get clobbered on every key.
            let field = ExpiryDateTextField()
            field.text = "12/30"
            field.sendActions(for: .editingChanged)
            XCTAssertEqual(field.text, "12/30")
        }
    }
#endif
