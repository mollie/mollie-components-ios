#if canImport(UIKit)
    import XCTest
    @testable import MolliePaymentsUI

    /// Digit-sanitisation tests for the CVC field. Same rationale as the
    /// PAN: `.numberPad` only filters the on-screen keyboard; hardware
    /// keyboards / paste / dictation can still inject anything.
    final class CVCTextFieldTests: XCTestCase {
        func test_digitsOnly_stripsLetters() {
            XCTAssertEqual(CVCTextField.digitsOnly("a1b2c3"), "123")
        }

        func test_digitsOnly_allDigits_unchanged() {
            XCTAssertEqual(CVCTextField.digitsOnly("123"), "123")
            XCTAssertEqual(CVCTextField.digitsOnly("1234"), "1234")
        }

        func test_digitsOnly_stripsSpaces() {
            XCTAssertEqual(CVCTextField.digitsOnly(" 1 2 3 "), "123")
        }

        @MainActor
        func test_editingChanged_stripsLetters() {
            let field = CVCTextField()
            field.text = "1a2b3"
            field.sendActions(for: .editingChanged)
            XCTAssertEqual(field.text, "123")
        }

        @MainActor
        func test_editingChanged_idempotent_noRewriteWhenAllDigits() {
            let field = CVCTextField()
            field.text = "123"
            field.sendActions(for: .editingChanged)
            XCTAssertEqual(field.text, "123")
        }
    }
#endif
