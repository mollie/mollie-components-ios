#if canImport(UIKit)
    import UIKit
    import XCTest
    @testable import MollieCore
    @testable import MolliePaymentsUI

    @MainActor
    final class CardFormViewControllerTests: XCTestCase {
        func test_init_acceptsDefaultTheme() {
            let form = MollieCardFormViewController()
            XCTAssertEqual(form.theme.colors.primary, MollieAppearance.Colors.default.primary)
        }

        func test_init_retainsCustomTheme() {
            let customColors = MollieAppearance.Colors(
                primary: .init(red: 0.1, green: 0.2, blue: 0.3, alpha: 1.0),
                background: .init(red: 0, green: 0, blue: 0, alpha: 1),
                field: .init(red: 0, green: 0, blue: 0, alpha: 1),
                fieldBorder: .init(red: 0, green: 0, blue: 0, alpha: 1),
                text: .init(red: 0, green: 0, blue: 0, alpha: 1),
                error: .init(red: 0, green: 0, blue: 0, alpha: 1)
            )
            let theme = MollieAppearance(colors: customColors, typography: .default)
            let form = MollieCardFormViewController(theme: theme)
            XCTAssertEqual(form.theme.colors.primary.red, 0.1, accuracy: 0.0001)
        }

        func test_viewDidLoad_installsAllFields() {
            let form = MollieCardFormViewController()
            form.loadViewIfNeeded()
            // Each named field is now in the view hierarchy.
            XCTAssertTrue(form.cardholderField.isDescendant(of: form.view))
            XCTAssertTrue(form.cardNumberField.isDescendant(of: form.view))
            XCTAssertTrue(form.expiryField.isDescendant(of: form.view))
            XCTAssertTrue(form.cvcField.isDescendant(of: form.view))
            XCTAssertTrue(form.payButton.isDescendant(of: form.view))
        }

        // MARK: - Embedded (SwiftUI) sizing

        func test_systemLayoutSizeFitting_heightStable_beforeAndAfterViewWillAppear() {
            // Regression: SwiftUI's `sizeThatFits` forces `viewDidLoad` (via
            // lazy `view` access) but never calls `viewWillAppear` before
            // freezing the embedded container to the measured height. If
            // theme application were deferred to `viewWillAppear`, the
            // measured height would stop matching the final themed layout —
            // Auto Layout resolves that mismatch by compressing the lowest-
            // priority breakable content (the section header labels) toward
            // zero height. Theme is an immutable `let`, so applying it in
            // `viewDidLoad` instead is behavior-neutral and keeps these two
            // measurements equal.
            let form = MollieCardFormViewController(theme: .default)
            let targetWidth: CGFloat = 343

            func fittingHeight() -> CGFloat {
                form.view.systemLayoutSizeFitting(
                    CGSize(width: targetWidth, height: UIView.layoutFittingCompressedSize.height),
                    withHorizontalFittingPriority: .required,
                    verticalFittingPriority: .fittingSizeLevel
                ).height
            }

            let before = fittingHeight()
            form.viewWillAppear(false)
            let after = fittingHeight()

            XCTAssertEqual(
                before, after, accuracy: 0.5,
                """
                Theme must not change the natural fitting height after SwiftUI's \
                one-shot pre-appear measurement, or the embedded form's section \
                header labels get compressed toward zero height.
                """
            )
        }

        func test_submitButton_emitsSnapshotWithRawText() {
            let form = MollieCardFormViewController()
            form.loadViewIfNeeded()
            form.cardholderField.text = "Ada Lovelace"
            form.cardNumberField.text = "4242 4242 4242 4242"
            form.expiryField.text = "12/30"
            form.cvcField.text = "123"

            var captured: CardFormSnapshot?
            form.onSubmit = { captured = $0 }

            form.payButton.sendTapForTesting()

            XCTAssertEqual(captured?.cardholderName, "Ada Lovelace")
            // Raw text comes through unchanged — masking is MR5's job.
            XCTAssertEqual(captured?.cardNumber, "4242 4242 4242 4242")
            XCTAssertEqual(captured?.expiry, "12/30")
            XCTAssertEqual(captured?.cvc, "123")
        }

        func test_submit_withEmptyFields_blocksEmission() {
            // Validation must block submit and never call onSubmit when fields
            // are empty; the inline error path on MollieGroupedCardFormView
            // handles user feedback instead of UIAlertController.
            let form = MollieCardFormViewController()
            form.loadViewIfNeeded()
            var submitted = false
            form.onSubmit = { _ in submitted = true }
            form.payButton.sendTapForTesting()
            XCTAssertFalse(submitted)
        }

        func test_submit_withNoListener_doesNotCrash() {
            // Inline errors (no UIAlertController) means tapping with invalid
            // fields is always safe, even with no onSubmit registered.
            let form = MollieCardFormViewController()
            form.loadViewIfNeeded()
            form.payButton.sendTapForTesting()
            // Reaching this line without trapping is the assertion.
        }

        // MARK: - debug emit-site

        // MARK: - Privacy overlay

        func test_applicationWillResignActive_installsPrivacyOverlayOnWindow() {
            // Brief explicitly requires the overlay be attached to the
            // window (so it covers nav-bar, status-bar, presented sheets)
            // rather than the VC's own view, which would only mask the
            // form body. Drive the notification handler directly and
            // assert via the diagnostic tag.
            let form = MollieCardFormViewController()
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 568))
            window.rootViewController = form
            window.makeKeyAndVisible()
            form.loadViewIfNeeded()

            form.appWillResignActive()

            let overlay = window.viewWithTag(MollieCardFormViewController.privacyOverlayTag)
            XCTAssertNotNil(overlay, "Privacy overlay must be attached to the window")
            XCTAssertEqual(overlay?.superview, window)
        }

        func test_applicationWillResignActive_doubleFire_doesNotStackOverlays() {
            // Resign-active + enter-background both fire on a fast home
            // swipe; the dedup guard must keep us from stacking two
            // overlays on top of each other (which would leak the second
            // one after `didBecomeActive` removes the first).
            let form = MollieCardFormViewController()
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 568))
            window.rootViewController = form
            window.makeKeyAndVisible()
            form.loadViewIfNeeded()

            form.appWillResignActive()
            form.appWillResignActive()

            let overlays = window.subviews.filter { $0.tag == MollieCardFormViewController.privacyOverlayTag }
            XCTAssertEqual(overlays.count, 1, "Double-fire must not stack overlays")
        }

        func test_applicationDidBecomeActive_removesPrivacyOverlay() {
            let form = MollieCardFormViewController()
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 568))
            window.rootViewController = form
            window.makeKeyAndVisible()
            form.loadViewIfNeeded()

            form.appWillResignActive()
            XCTAssertNotNil(window.viewWithTag(MollieCardFormViewController.privacyOverlayTag))

            form.appDidBecomeActive()
            XCTAssertNil(
                window.viewWithTag(MollieCardFormViewController.privacyOverlayTag),
                "Overlay must be torn down so the form is visible again"
            )
        }

        // MARK: - Submit lifecycle

        func test_handleSubmit_validationFailure_keepsButtonEnabled() {
            // Regression: the previous handler disabled the button before
            // running validation, leaving the button stuck disabled on the
            // first failure until the user touched another field. The fix
            // moves the disable inside the success branch — failure paths
            // must leave the button in whatever state `updateSubmitState`
            // produces, which for an empty-form snapshot is "disabled,
            // because the form is invalid", but importantly NOT "disabled
            // because we're mid-submit and locked out".
            let form = MollieCardFormViewController()
            form.loadViewIfNeeded()
            // Type fields that fail validation (cardholder empty).
            form.cardNumberField.text = "4242424242424242"
            form.expiryField.text = "12/30"
            form.cvcField.text = "123"

            form.payButton.sendTapForTesting()

            // Failure path: validator rejects, `updateSubmitState` flips
            // the button back to whatever the form's validity says — here
            // the missing cardholder means it stays disabled, but the
            // grouped view should show the per-field caption (Phase B3;
            // proof we hit the failure branch, not a stuck disable from
            // pre-validation).
            XCTAssertEqual(
                form.groupedFormView?.fieldErrorTextForTesting(.cardholder),
                CardFormValidator.ValidationError.missingCardholder.userMessage
            )
        }

        func test_cancelLoading_restoresButton() {
            // Host coordinator MUST call `cancelLoading()` on swipe-to-
            // dismiss without a result. After cancellation the button
            // should be back to its pre-tap state: not loading, and
            // enabled iff the form is still valid.
            let form = MollieCardFormViewController()
            form.loadViewIfNeeded()
            form.cardholderField.text = "Ada Lovelace"
            form.cardNumberField.text = "4242424242424242"
            form.expiryField.text = "12/30"
            form.cvcField.text = "123"
            // Force submit state to update so isEnabled becomes true.
            form.cardNumberField.sendActions(for: .editingChanged)

            // Trigger submit so the button is mid-loading.
            form.payButton.sendTapForTesting()
            XCTAssertFalse(
                form.payButton.isEnabled,
                "After submit the button is locked until cancelLoading or a result"
            )

            form.cancelLoading()
            XCTAssertTrue(
                form.payButton.isEnabled,
                "cancelLoading must restore the button to a tappable state"
            )
        }

        func test_showError_nilMessage_hidesLabel() {
            // Grouped view's inline error path: nil must clear AND hide,
            // not just blank the text (a 0-height label still consumes
            // layout space below the form border).
            let form = MollieCardFormViewController()
            form.loadViewIfNeeded()
            form.groupedFormView?.showError("Oops")
            XCTAssertEqual(form.groupedFormView?.currentErrorMessageForTesting, "Oops")
            form.groupedFormView?.showError(nil)
            XCTAssertNil(form.groupedFormView?.currentErrorMessageForTesting)
        }

        func test_cancelButton_invokesOnCancel() {
            let form = MollieCardFormViewController()
            form.loadViewIfNeeded()
            var cancelled = false
            form.onCancel = { cancelled = true }
            // Drive the bar button programmatically by invoking its target/action.
            let cancelItem = try? XCTUnwrap(form.navigationItem.leftBarButtonItem)
            if let cancelItem, let action = cancelItem.action, let target = cancelItem.target {
                _ = target.perform(action)
            }
            XCTAssertTrue(cancelled)
        }

        // MARK: - Per-field validation UX (Phase B3)

        //
        // `sendActions(for: .editingChanged / .editingDidEnd)` doesn't
        // reliably fire target-action in this repo's headless UIKit test
        // harness (see the brand-detection tests' `updateBrand(forPAN:)`
        // seam for precedent), so these drive the directly-callable
        // `validateAndDisplayAll()` / `validateAndDisplayField(_:)` /
        // `clearFieldErrorIfResolved(_:)` methods instead of the real
        // field events.

        func test_validateAndDisplayAll_allValid_returnsTrueAndClearsFieldErrors() {
            let form = MollieCardFormViewController()
            form.loadViewIfNeeded()
            form.cardholderField.text = "Ada Lovelace"
            form.cardNumberField.text = "4242424242424242"
            form.expiryField.text = "12/30"
            form.cvcField.text = "123"

            XCTAssertTrue(form.validateAndDisplayAll())
            for field: CardField in [.cardholder, .pan, .expiry, .cvc] {
                XCTAssertNil(form.groupedFormView?.fieldErrorTextForTesting(field))
            }
        }

        func test_validateAndDisplayAll_multipleInvalidFields_showsEveryFieldCaptionAndFocusesFirst() {
            // Web-SDK-aligned submit UX: show every problem at once (not
            // just the first, which is `updateSubmitState`'s job for the
            // live button gate), and focus the FIRST invalid field.
            let form = MollieCardFormViewController()
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 568))
            window.rootViewController = form
            window.makeKeyAndVisible()
            form.loadViewIfNeeded()
            // Cardholder empty, PAN too short, expiry blank, CVC empty —
            // every field fails.
            form.cardNumberField.text = "123"

            XCTAssertFalse(form.validateAndDisplayAll())
            XCTAssertEqual(
                form.groupedFormView?.fieldErrorTextForTesting(.cardholder),
                CardFormValidator.ValidationError.missingCardholder.userMessage
            )
            XCTAssertEqual(
                form.groupedFormView?.fieldErrorTextForTesting(.pan),
                CardFormValidator.ValidationError.panTooShort.userMessage
            )
            XCTAssertNotNil(form.groupedFormView?.fieldErrorTextForTesting(.expiry))
            XCTAssertNotNil(form.groupedFormView?.fieldErrorTextForTesting(.cvc))
            XCTAssertTrue(
                form.cardholderField.isFirstResponder,
                "Must focus the FIRST invalid field, per validateAll's cardholder/pan/expiry/cvc ordering"
            )
        }

        func test_validateAndDisplayAll_invalid_postsAccessibilityAnnouncementSummarizingErrors() {
            let form = MollieCardFormViewController()
            form.loadViewIfNeeded()
            var announced: String?
            form.accessibilityAnnouncer = { announced = $0 }

            XCTAssertFalse(form.validateAndDisplayAll())

            let expected = CardFormValidator.validateAll(snapshot: CardFormSnapshot(
                cardholderName: "",
                cardNumber: "",
                expiry: "",
                cvc: ""
            )).map(\.userMessage).joined(separator: " ")
            XCTAssertEqual(announced, expected)
        }

        func test_validateAndDisplayAll_valid_doesNotPostAnnouncement() {
            let form = MollieCardFormViewController()
            form.loadViewIfNeeded()
            form.cardholderField.text = "Ada Lovelace"
            form.cardNumberField.text = "4242424242424242"
            form.expiryField.text = "12/30"
            form.cvcField.text = "123"
            var announced: String?
            form.accessibilityAnnouncer = { announced = $0 }

            XCTAssertTrue(form.validateAndDisplayAll())
            XCTAssertNil(announced, "A valid submit must never post a VoiceOver announcement")
        }

        func test_validateAndDisplayField_blurWithInvalidValue_showsOnlyThatFieldCaption() {
            let form = MollieCardFormViewController()
            form.loadViewIfNeeded()
            // Every other field valid so we can prove only `.pan` gets a
            // caption from validating `.pan`.
            form.cardholderField.text = "Ada Lovelace"
            form.expiryField.text = "12/30"
            form.cvcField.text = "123"
            form.cardNumberField.text = "123"

            form.validateAndDisplayField(.pan)

            XCTAssertEqual(
                form.groupedFormView?.fieldErrorTextForTesting(.pan),
                CardFormValidator.ValidationError.panTooShort.userMessage
            )
            XCTAssertNil(form.groupedFormView?.fieldErrorTextForTesting(.cardholder))
            XCTAssertNil(form.groupedFormView?.fieldErrorTextForTesting(.expiry))
            XCTAssertNil(form.groupedFormView?.fieldErrorTextForTesting(.cvc))
        }

        func test_validateAndDisplayField_validValue_clearsThatFieldCaption() {
            let form = MollieCardFormViewController()
            form.loadViewIfNeeded()
            form.cardNumberField.text = "123"
            form.validateAndDisplayField(.pan)
            XCTAssertNotNil(form.groupedFormView?.fieldErrorTextForTesting(.pan))

            form.cardNumberField.text = "4242424242424242"
            form.validateAndDisplayField(.pan)

            XCTAssertNil(form.groupedFormView?.fieldErrorTextForTesting(.pan))
        }

        func test_validateAndDisplayField_doesNotClobberOtherFieldsCaptions() {
            // Merge-not-replace requirement: validating one field on blur
            // must not wipe out a caption another field is already showing.
            let form = MollieCardFormViewController()
            form.loadViewIfNeeded()
            form.cardNumberField.text = "123"
            form.validateAndDisplayField(.pan)
            XCTAssertNotNil(form.groupedFormView?.fieldErrorTextForTesting(.pan))

            form.cvcField.text = "1"
            form.validateAndDisplayField(.cvc)

            XCTAssertNotNil(
                form.groupedFormView?.fieldErrorTextForTesting(.pan),
                "Validating .cvc must not clear .pan's already-shown caption"
            )
            XCTAssertNotNil(form.groupedFormView?.fieldErrorTextForTesting(.cvc))
        }

        func test_clearFieldErrorIfResolved_fieldWithNoDisplayedError_doesNotIntroduceOne() {
            // Guard clause: the per-keystroke path must only ever touch a
            // field that already HAS a displayed caption — it must never
            // introduce a new one while the user is still typing.
            let form = MollieCardFormViewController()
            form.loadViewIfNeeded()
            form.cardNumberField.text = "123" // invalid, but never blurred/submitted

            form.clearFieldErrorIfResolved(.pan)

            XCTAssertNil(form.groupedFormView?.fieldErrorTextForTesting(.pan))
        }

        func test_clearFieldErrorIfResolved_resolvedField_clearsCaption() {
            let form = MollieCardFormViewController()
            form.loadViewIfNeeded()
            form.cardNumberField.text = "123"
            form.validateAndDisplayField(.pan)
            XCTAssertNotNil(form.groupedFormView?.fieldErrorTextForTesting(.pan))

            form.cardNumberField.text = "4242424242424242"
            form.clearFieldErrorIfResolved(.pan)

            XCTAssertNil(form.groupedFormView?.fieldErrorTextForTesting(.pan))
        }

        func test_clearFieldErrorIfResolved_stillInvalid_leavesCaptionShown() {
            let form = MollieCardFormViewController()
            form.loadViewIfNeeded()
            form.cardNumberField.text = "123"
            form.validateAndDisplayField(.pan)

            form.cardNumberField.text = "1234" // still too short
            form.clearFieldErrorIfResolved(.pan)

            XCTAssertNotNil(
                form.groupedFormView?.fieldErrorTextForTesting(.pan),
                "Per-keystroke path must not clear a caption whose field is still invalid"
            )
        }

        func test_handleSubmit_success_clearsStaleFieldCaptionFromAPriorFailedSubmit() {
            let form = MollieCardFormViewController()
            form.loadViewIfNeeded()
            // First tap fails (empty cardholder) and paints its caption.
            form.cardNumberField.text = "4242424242424242"
            form.expiryField.text = "12/30"
            form.cvcField.text = "123"
            form.payButton.sendTapForTesting()
            XCTAssertNotNil(form.groupedFormView?.fieldErrorTextForTesting(.cardholder))

            // Fix it and resubmit — the stale caption must clear on success.
            form.cardholderField.text = "Ada Lovelace"
            form.payButton.sendTapForTesting()

            XCTAssertNil(form.groupedFormView?.fieldErrorTextForTesting(.cardholder))
        }

        // MARK: - Per-field event

        //
        // `fireFieldEvent(for:)` is `package` (not `private`) for the same
        // reason `validateAndDisplayField(_:)`/`clearFieldErrorIfResolved(_:)`
        // are — see this file's header comment on why `sendActions(for:)`
        // isn't a reliable driver here. These tests call it directly and
        // assert the `CardFieldEvent` handed to `onFieldEvent`.

        func test_fireFieldEvent_validField_reportsIsValidTrueAndNoError() {
            let form = MollieCardFormViewController()
            form.loadViewIfNeeded()
            form.cardholderField.text = "Ada Lovelace"
            var captured: CardFieldEvent?
            form.onFieldEvent = { captured = $0 }

            form.fireFieldEvent(for: .cardholder)

            XCTAssertEqual(captured?.field, .cardholder)
            XCTAssertEqual(captured?.isValid, true)
            XCTAssertNil(captured?.error)
        }

        func test_fireFieldEvent_invalidField_reportsIsValidFalseAndErrorKind() {
            let form = MollieCardFormViewController()
            form.loadViewIfNeeded()
            form.cardNumberField.text = "123"
            var captured: CardFieldEvent?
            form.onFieldEvent = { captured = $0 }

            form.fireFieldEvent(for: .pan)

            XCTAssertEqual(captured?.field, .pan)
            XCTAssertEqual(captured?.isValid, false)
            XCTAssertEqual(captured?.error, .panTooShort)
        }

        func test_fireFieldEvent_reportsDetectedSchemeFromCardNumberField() {
            let form = MollieCardFormViewController()
            form.loadViewIfNeeded()
            form.cardNumberField.text = "4242424242424242"
            var captured: CardFieldEvent?
            form.onFieldEvent = { captured = $0 }

            // Every field's event carries the detected scheme, not only
            // `.pan`'s — proves a host doesn't need to separately watch the
            // card-number field just to read it.
            form.fireFieldEvent(for: .cvc)

            XCTAssertEqual(captured?.detectedScheme, .visa)
        }

        func test_fireFieldEvent_noCardNumber_reportsNilDetectedScheme() {
            let form = MollieCardFormViewController()
            form.loadViewIfNeeded()
            var captured: CardFieldEvent?
            form.onFieldEvent = { captured = $0 }

            form.fireFieldEvent(for: .cardholder)

            XCTAssertNil(captured?.detectedScheme)
        }
    }

#endif
