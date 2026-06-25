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
    }
#endif
