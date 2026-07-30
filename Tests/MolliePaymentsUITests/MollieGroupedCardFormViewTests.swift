#if canImport(UIKit)
    import UIKit
    import XCTest
    @testable import MolliePaymentsUI

    /// Per-field error captions. Exercises `showFieldErrors(_:)`
    /// directly against `MollieGroupedCardFormView`, and confirms the
    /// pre-existing `showError(_:)` single-message API keeps working
    /// unchanged alongside it.
    @MainActor
    final class MollieGroupedCardFormViewTests: XCTestCase {
        private func makeSubject() -> MollieGroupedCardFormView {
            MollieGroupedCardFormView(
                cardNumberField: CardNumberTextField(),
                expiryField: ExpiryDateTextField(),
                cvcField: CVCTextField(),
                cardholderField: CardholderTextField()
            )
        }

        func test_showFieldErrors_showsMessageForEachReportedField() {
            let subject = makeSubject()

            subject.showFieldErrors([
                .cardholder: "Enter the name on your card.",
                .pan: "Your card number looks too short.",
                .expiry: "Enter expiry as MM/YY.",
                .cvc: "CVC must be 3 or 4 digits.",
            ])

            XCTAssertEqual(subject.fieldErrorTextForTesting(.cardholder), "Enter the name on your card.")
            XCTAssertEqual(subject.fieldErrorTextForTesting(.pan), "Your card number looks too short.")
            XCTAssertEqual(subject.fieldErrorTextForTesting(.expiry), "Enter expiry as MM/YY.")
            XCTAssertEqual(subject.fieldErrorTextForTesting(.cvc), "CVC must be 3 or 4 digits.")
        }

        func test_showFieldErrors_hidesFieldsMissingFromTheDictionary() {
            let subject = makeSubject()

            subject.showFieldErrors([.pan: "Your card number looks too short."])

            XCTAssertEqual(subject.fieldErrorTextForTesting(.pan), "Your card number looks too short.")
            XCTAssertNil(subject.fieldErrorTextForTesting(.cardholder))
            XCTAssertNil(subject.fieldErrorTextForTesting(.expiry))
            XCTAssertNil(subject.fieldErrorTextForTesting(.cvc))
        }

        func test_showFieldErrors_emptyStringHidesTheField() {
            let subject = makeSubject()

            subject.showFieldErrors([.cvc: "CVC must be 3 or 4 digits."])
            XCTAssertNotNil(subject.fieldErrorTextForTesting(.cvc))

            subject.showFieldErrors([.cvc: ""])
            XCTAssertNil(subject.fieldErrorTextForTesting(.cvc))
        }

        func test_showFieldErrors_clearsPreviouslyShownFieldsNotInNewCall() {
            let subject = makeSubject()

            subject.showFieldErrors([.pan: "Your card number looks too short.", .cvc: "CVC must be 3 or 4 digits."])
            XCTAssertNotNil(subject.fieldErrorTextForTesting(.pan))
            XCTAssertNotNil(subject.fieldErrorTextForTesting(.cvc))

            // A later call reporting only the CVC failure must re-hide the
            // PAN caption — callers pass the full current error set each
            // time, not a diff.
            subject.showFieldErrors([.cvc: "CVC must be 3 or 4 digits."])
            XCTAssertNil(subject.fieldErrorTextForTesting(.pan))
            XCTAssertNotNil(subject.fieldErrorTextForTesting(.cvc))
        }

        func test_showFieldErrors_emptyDictionaryHidesAllFields() {
            let subject = makeSubject()

            subject.showFieldErrors([.cardholder: "Enter the name on your card."])
            subject.showFieldErrors([:])

            XCTAssertNil(subject.fieldErrorTextForTesting(.cardholder))
            XCTAssertNil(subject.fieldErrorTextForTesting(.pan))
            XCTAssertNil(subject.fieldErrorTextForTesting(.expiry))
            XCTAssertNil(subject.fieldErrorTextForTesting(.cvc))
        }

        func test_showError_stillWorksAlongsideShowFieldErrors() {
            let subject = makeSubject()

            subject.showFieldErrors([.pan: "Your card number looks too short."])
            subject.showError("Oops")

            XCTAssertEqual(subject.currentErrorMessageForTesting, "Oops")
            // The shared message and the per-field caption are independent
            // surfaces; setting one must not clear the other.
            XCTAssertEqual(subject.fieldErrorTextForTesting(.pan), "Your card number looks too short.")

            subject.showError(nil)
            XCTAssertNil(subject.currentErrorMessageForTesting)
            XCTAssertEqual(subject.fieldErrorTextForTesting(.pan), "Your card number looks too short.")
        }

        // MARK: - B4 focus/blur border (native system tint)

        /// `sendActions(for: .editingDidBegin/.editingDidEnd)` doesn't
        /// reliably fire in the headless-sim test harness, so these drive
        /// `applyFocusState(to:focused:)` directly — the same seam the
        /// fields' `editingDidBegin`/`editingDidEnd` targets call into.
        func test_applyFocusState_focused_setsContainerBorderToSystemTint() {
            let subject = makeSubject()

            subject.applyFocusState(to: subject.cardNumberField, focused: true)

            XCTAssertEqual(subject.borderColorForTesting(subject.cardNumberField), subject.tintColor.cgColor)
        }

        func test_applyFocusState_blurred_restoresThemedDefaultBorder() {
            let subject = makeSubject()
            subject.applyTheme(.default)

            subject.applyFocusState(to: subject.cardNumberField, focused: true)
            subject.applyFocusState(to: subject.cardNumberField, focused: false)

            XCTAssertEqual(
                subject.borderColorForTesting(subject.cardNumberField),
                MollieAppearance.default.colors.fieldBorder.uiColor.cgColor
            )
            XCTAssertEqual(
                subject.borderWidthForTesting(subject.cardNumberField),
                MollieAppearance.default.fieldBorderWidth
            )
        }

        func test_applyFocusState_focused_bumpsBorderWidthAboveThemedDefault() {
            let subject = makeSubject()
            subject.applyTheme(.default)

            subject.applyFocusState(to: subject.cardNumberField, focused: true)

            XCTAssertGreaterThan(
                subject.borderWidthForTesting(subject.cardNumberField),
                MollieAppearance.default.fieldBorderWidth
            )
        }

        /// Card number, expiry, and CVC are visually one collapsed group
        /// (G5) sharing a single bordered container — focusing any one of
        /// them must tint that same shared border.
        func test_applyFocusState_cardNumberExpiryAndCVCShareOneContainer() {
            let subject = makeSubject()

            subject.applyFocusState(to: subject.expiryField, focused: true)

            XCTAssertEqual(subject.borderColorForTesting(subject.cardNumberField), subject.tintColor.cgColor)
            XCTAssertEqual(subject.borderColorForTesting(subject.cvcField), subject.tintColor.cgColor)
        }

        /// The cardholder field has its own bordered container — focusing
        /// it must not tint the card-information group's border.
        func test_applyFocusState_cardholderContainerIsIndependentOfCardInfoGroup() {
            let subject = makeSubject()
            subject.applyTheme(.default)

            subject.applyFocusState(to: subject.cardholderField, focused: true)

            XCTAssertEqual(subject.borderColorForTesting(subject.cardholderField), subject.tintColor.cgColor)
            XCTAssertEqual(
                subject.borderColorForTesting(subject.cardNumberField),
                MollieAppearance.default.colors.fieldBorder.uiColor.cgColor
            )
        }

        /// Re-theming (e.g. a light/dark trait change) must not silently
        /// drop the focus ring on a field that's still being edited. Needs
        /// a real key window so `becomeFirstResponder()` succeeds — skips
        /// (rather than false-failing) if the headless harness won't grant
        /// first-responder status.
        func test_applyTheme_reassertsFocusRingOnStillFirstResponderField() throws {
            let subject = makeSubject()
            let window = UIWindow()
            window.addSubview(subject)
            window.makeKeyAndVisible()
            try XCTSkipUnless(subject.cardNumberField.becomeFirstResponder(), "harness won't grant first responder")
            subject.applyFocusState(to: subject.cardNumberField, focused: true)

            subject.applyTheme(.default)

            XCTAssertEqual(subject.borderColorForTesting(subject.cardNumberField), subject.tintColor.cgColor)
        }
    }
#endif
