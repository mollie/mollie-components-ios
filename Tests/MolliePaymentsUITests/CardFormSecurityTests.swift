#if canImport(UIKit)
    import UIKit
    import XCTest
    @testable import MolliePaymentsUI

    /// Security-hardening behaviours on the card form: secure-input mode,
    /// pasteboard action blocking, and lifecycle-driven field wiping.
    /// Companion to `CardFormViewControllerTests` which covers the
    /// functional surface; this file pins the defensive contracts so a
    /// future refactor can't silently regress them.
    @MainActor
    final class CardFormSecurityTests: XCTestCase {
        // MARK: - Secure input mode

        func test_cardNumberField_isNotSecureEntry() {
            let field = CardNumberTextField()
            XCTAssertFalse(
                field.isSecureTextEntry,
                "PAN must render as plaintext while typing — matches industry-standard card-entry UIs and the Mollie Web SDK. Hiding the digits drove typos and retries (which re-expose the PAN more than any screen recorder ever would). This is a deliberate tradeoff: isSecureTextEntry is also what forces the system keyboard and locks out third-party keyboard extensions, but on a long, error-prone field that protection isn't worth the retry cost. Other defences — copy/cut block, no dictation cache, masked accessibilityValue, lifecycle wipes — remain in place."
            )
        }

        func test_cvcField_isSecureEntry() {
            let field = CVCTextField()
            XCTAssertTrue(
                field.isSecureTextEntry,
                "CVC must be in secure-entry mode. isSecureTextEntry is the only iOS control that forces the system keyboard, which locks third-party keyboard extensions out of this field even when the user has granted one Full Access. A 3-/4-digit code masks at negligible UX cost, and the CVC is what turns a stolen PAN into a usable card-not-present transaction — so unlike the PAN, the keyboard-extension lockout is worth taking here."
            )
        }

        // MARK: - Pasteboard action blocking

        func test_cardNumberField_blocksCopyAction() {
            let field = CardNumberTextField()
            XCTAssertFalse(
                field.canPerformAction(#selector(UIResponder.copy(_:)), withSender: nil),
                "Copying the typed PAN would put it on the process-global system pasteboard"
            )
        }

        func test_cardNumberField_blocksCutAction() {
            let field = CardNumberTextField()
            XCTAssertFalse(
                field.canPerformAction(#selector(UIResponder.cut(_:)), withSender: nil),
                "Cutting the typed PAN would put it on the process-global system pasteboard"
            )
        }

        func test_cardNumberField_allowsPasteAction() {
            let field = CardNumberTextField()
            // Paste must remain available — password managers and merchant
            // ops both rely on pasting full PANs from external sources.
            // The pasteboard is the *source*, not the destination, so the
            // PCI surface stays unchanged.
            XCTAssertTrue(
                field.canPerformAction(#selector(UIResponder.paste(_:)), withSender: nil),
                "Pasting into the PAN field must stay available for password-manager flows"
            )
        }

        func test_cvcField_blocksCopyAction() {
            let field = CVCTextField()
            XCTAssertFalse(
                field.canPerformAction(#selector(UIResponder.copy(_:)), withSender: nil),
                "Copying the typed CVC would put it on the process-global system pasteboard"
            )
        }

        func test_cvcField_blocksCutAction() {
            let field = CVCTextField()
            XCTAssertFalse(
                field.canPerformAction(#selector(UIResponder.cut(_:)), withSender: nil)
            )
        }

        // MARK: - Lifecycle-driven wipes

        func test_handleSubmit_wipesPanAndCvcButPreservesNameAndExpiry() {
            let form = MollieCardFormViewController()
            form.loadViewIfNeeded()
            form.cardholderField.text = "Ada Lovelace"
            form.cardNumberField.text = "4242424242424242"
            form.expiryField.text = "12/30"
            form.cvcField.text = "123"

            // Capture the snapshot the form emits so we can assert the
            // wipe happens *after* delivery to the host, not before.
            var captured: CardFormSnapshot?
            form.onSubmit = { captured = $0 }

            form.payButton.sendTapForTesting()

            XCTAssertNotNil(captured, "Submit must reach the host before any wipe")
            XCTAssertEqual(captured?.cardNumber, "4242424242424242")
            XCTAssertEqual(captured?.cvc, "123")

            XCTAssertEqual(form.cardNumberField.text, "", "PAN field must be wiped after submit")
            XCTAssertEqual(form.cvcField.text, "", "CVC field must be wiped after submit")
            XCTAssertEqual(
                form.cardholderField.text,
                "Ada Lovelace",
                "Name is not PCI; preserved across submit so retries don't force a full re-type"
            )
            XCTAssertEqual(
                form.expiryField.text,
                "12/30",
                "Expiry is not PCI; preserved across submit"
            )
        }

        func test_handleSubmit_validationFailure_doesNotWipe() {
            let form = MollieCardFormViewController()
            form.loadViewIfNeeded()
            // Empty PAN trips the validator — submit must NOT fire onSubmit
            // and must NOT wipe (the user is mid-typing and would lose
            // any digits they had entered if a typo elsewhere triggered
            // the failure path).
            form.cardholderField.text = "Ada Lovelace"
            form.cardNumberField.text = "4242"
            form.expiryField.text = "12/30"
            form.cvcField.text = "123"

            var captured: CardFormSnapshot?
            form.onSubmit = { captured = $0 }

            form.payButton.sendTapForTesting()

            XCTAssertNil(captured, "Validation failure must short-circuit before onSubmit")
            XCTAssertEqual(
                form.cardNumberField.text,
                "4242",
                "Validation failure must NOT wipe the field — user keeps mid-entry state"
            )
            XCTAssertEqual(form.cvcField.text, "123")
        }

        func test_viewWillDisappear_wipesPanAndCvc() {
            let form = MollieCardFormViewController()
            form.loadViewIfNeeded()
            form.cardNumberField.text = "4242424242424242"
            form.cvcField.text = "123"
            form.cardholderField.text = "Ada Lovelace"
            form.expiryField.text = "12/30"

            form.beginAppearanceTransition(false, animated: false)
            form.endAppearanceTransition()

            XCTAssertEqual(form.cardNumberField.text, "", "Form leaving the screen must drop the PAN reference")
            XCTAssertEqual(form.cvcField.text, "", "Form leaving the screen must drop the CVC reference")
            XCTAssertEqual(form.cardholderField.text, "Ada Lovelace", "Name preserved on dismount")
            XCTAssertEqual(form.expiryField.text, "12/30", "Expiry preserved on dismount")
        }
    }
#endif
