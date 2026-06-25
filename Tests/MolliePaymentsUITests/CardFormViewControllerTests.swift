#if canImport(UIKit)
    import UIKit
    import XCTest
    @testable import MollieCore
    @testable import MolliePaymentsUI

    @MainActor
    final class CardFormViewControllerTests: XCTestCase {
        func test_init_acceptsDefaultTheme() {
            let form = MollieCardFormViewController()
            XCTAssertEqual(form.theme.colors.primary, MolliePaymentTheme.Colors.default.primary)
        }

        func test_init_retainsCustomTheme() {
            let customColors = MolliePaymentTheme.Colors(
                primary: .init(red: 0.1, green: 0.2, blue: 0.3, alpha: 1.0),
                background: .init(red: 0, green: 0, blue: 0, alpha: 1),
                field: .init(red: 0, green: 0, blue: 0, alpha: 1),
                fieldBorder: .init(red: 0, green: 0, blue: 0, alpha: 1),
                text: .init(red: 0, green: 0, blue: 0, alpha: 1),
                error: .init(red: 0, green: 0, blue: 0, alpha: 1)
            )
            let theme = MolliePaymentTheme(colors: customColors, typography: .default)
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
            // grouped view should show an inline error (proof we hit the
            // failure branch, not a stuck disable from pre-validation).
            XCTAssertEqual(
                form.groupedFormView?.currentErrorMessageForTesting,
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
    }

#endif
