#if canImport(UIKit)
    import MollieCore
    import UIKit

    /// Empty card-form view-controller. MR4 ships the layout + field wiring;
    /// MR5 layers masking / validation / IIN / submit-gating; MR6 applies
    /// theme tokens to colours and fonts.
    ///
    /// The controller intentionally knows nothing about
    /// `CardPaymentCoordinator` or any sheet/navigation concern. It exposes a
    /// callback (`onSubmit`) that emits a raw `CardFormSnapshot`; the consumer
    /// (today `PaymentSheetCoordinator` in MR3, future
    /// `MolliePaymentFormController` post-MVP) decides what to do with it.
    @MainActor
    package final class MollieCardFormViewController: UIViewController {
        package let theme: MolliePaymentTheme
        package var onSubmit: ((CardFormSnapshot) -> Void)?
        package var onCancel: (() -> Void)?

        package let cardholderField = CardholderTextField()
        package let cardNumberField = CardNumberTextField()
        package let expiryField = ExpiryDateTextField()
        package let cvcField = CVCTextField()
        package let payButton = MollieStyledPayButton()

        /// Grouped container that owns the rounded border + dividers around
        /// the four fields. Created in `installLayout()`; surfaced as `package`
        /// so `MolliePaymentThemeApplier` can re-theme it without reaching
        /// into the view hierarchy.
        package private(set) var groupedFormView: MollieGroupedCardFormView?

        /// All four custom field subclasses in display order. Surfaced so the
        /// theme applier can iterate without re-listing names.
        package var cardFields: [UITextField] {
            [cardholderField, cardNumberField, expiryField, cvcField]
        }

        package init(theme: MolliePaymentTheme = MolliePaymentTheme()) {
            self.theme = theme
            super.init(nibName: nil, bundle: nil)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("MollieCardFormViewController does not support NSCoder")
        }

        override package func viewDidLoad() {
            super.viewDidLoad()
            // Title intentionally nil: the form's own "Card information" /
            // "Card holder" section labels carry the screen meaning, and the
            // primary CTA reads "Pay with card" — a duplicated nav title
            // would just add noise. Cancel bar button stays as the only
            // dismissal affordance.
            title = nil
            navigationItem.leftBarButtonItem = UIBarButtonItem(
                barButtonSystemItem: .cancel,
                target: self,
                action: #selector(handleCancel)
            )
            installLayout()
            configureSubmit()
            // Gate the submit button on form validity; starts disabled so the
            // user cannot tap before entering anything.
            updateSubmitState()
            // App-switcher snapshot scrub: cover the window before iOS
            // captures the snapshot, uncover when we come back to the
            // foreground. Listen on BOTH `willResignActive` (covers control
            // centre / incoming call) AND `didEnterBackground` (covers a
            // fast home-swipe that can skip the resign-active edge on some
            // iOS versions); the dedup guard inside the handler keeps a
            // double-fire from stacking overlays.
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(appWillResignActive),
                name: UIApplication.willResignActiveNotification,
                object: nil
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(appWillResignActive),
                name: UIApplication.didEnterBackgroundNotification,
                object: nil
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(appDidBecomeActive),
                name: UIApplication.didBecomeActiveNotification,
                object: nil
            )
            // Screen-recording / mirroring scrub: same overlay machinery as
            // the app-switcher path. Fires when the user starts recording
            // (Control Centre), AirPlay-mirrors to a TV, or any other path
            // that flips `UIScreen.isCaptured`. Without this an attacker
            // who social-engineers a victim into "share your screen to
            // support" can capture the typed PAN visually.
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(screenCaptureDidChange),
                name: UIScreen.capturedDidChangeNotification,
                object: nil
            )
        }

        deinit {
            // NotificationCenter on iOS 9+ no longer requires manual removal
            // for `addObserver(_:selector:...)`, but Mollie's lint baseline
            // and the legacy iOS-10/11 ports we still need to honour both
            // expect an explicit cleanup. Cheap and surfaces leaks in tests.
            NotificationCenter.default.removeObserver(self)
        }

        override package func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            // Theme is applied late so a host that mutates the theme after
            // init still sees the right values. Re-applied on trait changes
            // so a dark-mode switch mid-flow recolours.
            MolliePaymentThemeApplier.apply(theme, to: self)
            // If the user already had screen recording active when the form
            // first becomes visible, the capturedDidChange notification has
            // already fired (before we subscribed). Re-evaluate on appear
            // so we don't ship the form unprotected in that case.
            screenCaptureDidChange()
        }

        override package func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            // Form is going away — drop the typed PAN/CVC references so a
            // re-mount (or a leak that keeps the VC alive) doesn't bring
            // the sensitive values back. Non-sensitive fields stay so the
            // user's name/expiry survive a brief navigation.
            wipeSensitiveFields()
        }

        override package func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
            super.traitCollectionDidChange(previousTraitCollection)
            guard traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) else { return }
            MolliePaymentThemeApplier.apply(theme, to: self)
        }

        private func installLayout() {
            // Grouped container owns field borders, dividers, and the inline
            // error label; the VC just stacks it above the submit button.
            let grouped = MollieGroupedCardFormView(
                cardNumberField: cardNumberField,
                expiryField: expiryField,
                cvcField: cvcField,
                cardholderField: cardholderField
            )
            groupedFormView = grouped

            // Per-field height + dynamic type stays here — the grouped view
            // pins a `>= 44` minimum, but accessibility scaling still needs
            // `adjustsFontForContentSizeCategory` on each field.
            for field in [cardholderField, cardNumberField, expiryField, cvcField] {
                field.adjustsFontForContentSizeCategory = true
                field.font = UIFont.preferredFont(forTextStyle: .body)
            }

            let stack = UIStackView(arrangedSubviews: [grouped, payButton])
            stack.axis = .vertical
            stack.spacing = 24
            stack.translatesAutoresizingMaskIntoConstraints = false

            view.addSubview(stack)
            let guide = view.safeAreaLayoutGuide
            NSLayoutConstraint.activate([
                stack.topAnchor.constraint(equalTo: guide.topAnchor, constant: 20),
                stack.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 20),
                stack.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -20),
                // Bottom constraint is `lessThanOrEqual` so the modal sheet
                // path (where the VC owns the full screen) still leaves
                // empty space below the form, while the embedded path
                // (where this VC is wrapped in a `UIViewControllerRepresentable`)
                // gets a finite intrinsic content size from
                // `systemLayoutSizeFitting` instead of stretching forever.
                stack.bottomAnchor.constraint(lessThanOrEqualTo: guide.bottomAnchor, constant: -20),
            ])
        }

        private func configureSubmit() {
            payButton.setTitle("Pay with card")
            payButton.onTap = { [weak self] in self?.handleSubmit() }
            // Re-evaluate validity on every keystroke in any of the four fields.
            for field in cardFields {
                field.addTarget(self, action: #selector(updateSubmitState), for: .editingChanged)
            }
        }

        private func currentSnapshot() -> CardFormSnapshot {
            CardFormSnapshot(
                cardholderName: cardholderField.text ?? "",
                cardNumber: cardNumberField.text ?? "",
                expiry: expiryField.text ?? "",
                cvc: cvcField.text ?? ""
            )
        }

        @objc private func updateSubmitState() {
            let validationResult = CardFormValidator.validate(snapshot: currentSnapshot())
            payButton.isEnabled = (validationResult == nil)
        }

        @objc private func handleSubmit() {
            // Validate first; only commit the disable + spinner once we know
            // the snapshot will actually flow to the host coordinator. The
            // previous order disabled the button before validation, which
            // briefly stuck the button as disabled on validation failure
            // before `updateSubmitState()` rehydrated it — visible as a
            // flicker, and an accessibility regression for VoiceOver users
            // who hear the state change twice.
            var snapshot = currentSnapshot()
            if let error = CardFormValidator.validate(snapshot: snapshot) {
                groupedFormView?.showError(error.userMessage)
                focusField(for: error)
                updateSubmitState()
            } else {
                groupedFormView?.showError(nil)
                // Disable + spin: prevents double-tap re-entry while the host
                // coordinator is in flight. The host must call
                // `cancelLoading()` on dismiss-without-result, otherwise the
                // button stays locked.
                payButton.isEnabled = false
                payButton.setLoading(true)
                onSubmit?(snapshot)
                // Zero out the producer-side copy after the closure has run
                // so the PAN/CVC references stop living on the VC's stack
                // frame for any longer than necessary. The closure itself
                // (e.g. the host coordinator) received a value-type copy
                // and is responsible for zeroing its own snapshot once it
                // has handed the PAN to the tokeniser — we can only
                // guarantee the producer-side reference is dropped here.
                snapshot.zero()
                // Also drop the PAN/CVC references held by the on-screen
                // text fields themselves. Without this, a host that swipes
                // away post-submit (or backgrounds the app, or screen-
                // records) sees the typed digits still living on
                // `UITextField.text`. Name + expiry are preserved so a
                // retry after a network failure only requires re-typing
                // the sensitive fields.
                wipeSensitiveFields()
            }
        }

        /// Reset the submit button to its pre-tap state. Hosts MUST call this
        /// when the sheet dismisses without delivering a tokenisation result
        /// (e.g. swipe-to-dismiss mid-flight) so the form can be reused. The
        /// VC cannot infer dismissal on its own because the host owns the
        /// presentation context.
        package func cancelLoading() {
            payButton.setLoading(false)
            updateSubmitState()
        }

        private func focusField(for error: CardFormValidator.ValidationError) {
            switch error.fieldKind {
            case .cardholder: cardholderField.becomeFirstResponder()
            case .pan: cardNumberField.becomeFirstResponder()
            case .expiry: expiryField.becomeFirstResponder()
            case .cvc: cvcField.becomeFirstResponder()
            }
        }

        @objc private func handleCancel() {
            onCancel?()
        }

        /// Tag used for diagnostic identification of the privacy overlay;
        /// the real lifecycle handle is the weak `privacyOverlay` ref so the
        /// view never outlives its window.
        package static let privacyOverlayTag = 0x4D4F_4C4C // "MOLL"

        /// Weak reference to the privacy overlay attached to the host
        /// window. Weak because the window owns the overlay's lifetime —
        /// holding a strong ref here would leak the overlay past
        /// `removeFromSuperview` in degenerate teardown orders.
        private weak var privacyOverlay: UIView?

        @objc package func appWillResignActive() {
            // Attach to the *window*, not `self.view`, so the overlay covers
            // the entire UI (status bar, nav bar, presented sheets) — the
            // app-switcher snapshot is taken at window scope, and an overlay
            // pinned to the VC's own view would only mask the form body.
            // The dedup guard keeps a double-fire (resignActive + enterBg)
            // from stacking two overlays on top of each other.
            guard let window = view.window, privacyOverlay == nil else { return }
            let overlay = UIView(frame: window.bounds)
            overlay.backgroundColor = theme.colors.background.uiColor
            overlay.tag = Self.privacyOverlayTag
            overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            window.addSubview(overlay)
            privacyOverlay = overlay
        }

        @objc package func appDidBecomeActive() {
            // Only tear down the overlay if no other capture path is still
            // active (e.g. resigned-active fired *and* screen recording is
            // ongoing). The screen-capture handler will re-evaluate next.
            guard !isScreenCurrentlyCaptured() else { return }
            privacyOverlay?.removeFromSuperview()
            privacyOverlay = nil
        }

        /// Toggle the privacy overlay in response to a screen-capture state
        /// change. Same overlay machinery as the app-switcher path. When
        /// capture starts, attach the overlay; when it stops, drop it
        /// (unless the app is still backgrounded, in which case the
        /// resignActive path keeps it up).
        @objc package func screenCaptureDidChange() {
            if isScreenCurrentlyCaptured() {
                appWillResignActive()
            } else {
                privacyOverlay?.removeFromSuperview()
                privacyOverlay = nil
            }
        }

        /// Resolves the current screen-capture flag via the window's screen
        /// when available (iOS 13+ multi-scene API) with a fallback to
        /// `UIScreen.main`. `UIScreen.main` still works as of iOS 18 but
        /// emits a deprecation warning under strict SDK settings; the
        /// fallback keeps us safe when the view hasn't been attached to a
        /// window yet (e.g. during `viewDidLoad`).
        private func isScreenCurrentlyCaptured() -> Bool {
            if let screen = view.window?.windowScene?.screen {
                return screen.isCaptured
            }
            return UIScreen.main.isCaptured
        }

        /// Drop the producer-side PAN + CVC references held by the on-
        /// screen text fields. Swift `String` is immutable and copy-on-
        /// write — setting `.text = ""` doesn't memset the underlying
        /// bytes, but it does release our reference so ARC can free the
        /// heap buffer at the next refcount drop. Best-effort: a
        /// determined attacker with `mach_vm_read` can still scrape the
        /// live process memory. Name + expiry stay so a retry after a
        /// network failure doesn't force a full re-type.
        private func wipeSensitiveFields() {
            cardNumberField.text = ""
            cvcField.text = ""
        }
    }
#endif
