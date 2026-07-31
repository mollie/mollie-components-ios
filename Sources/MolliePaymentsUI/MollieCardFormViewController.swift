#if canImport(UIKit)
    import MollieCore
    import MolliePayments
    import UIKit

    /// Card-form view-controller. Ships the layout + field wiring, masking /
    /// validation / IIN / submit-gating, and theme tokens applied to colours
    /// and fonts.
    ///
    /// The controller intentionally knows nothing about
    /// `CardPaymentCoordinator` or any sheet/navigation concern. It exposes a
    /// callback (`onSubmit`) that emits a raw `CardFormSnapshot`; the consumer
    /// (`MollieCheckout`'s modal coordinator or `MollieCardComponent`'s embed
    /// bridge, both in `MollieComponents`) decides what to do with it.
    @MainActor
    package final class MollieCardFormViewController: UIViewController {
        package let theme: MollieAppearance
        package var onSubmit: ((CardFormSnapshot) -> Void)?
        package var onCancel: (() -> Void)?
        /// Fired on every per-keystroke edit and on blur for the field
        /// affected, reporting that field's live validity, error (if any),
        /// and the currently-detected card scheme. `MollieComponents` maps
        /// this to the public `MollieCardFieldEvent` surface — see
        /// `CardFieldEvent`'s doc comment for why the underlying
        /// `CardField`/`CardScheme` types stay package-private.
        package var onFieldEvent: ((CardFieldEvent) -> Void)?

        package let cardholderField = CardholderTextField()
        package let cardNumberField = CardNumberTextField()
        package let expiryField = ExpiryDateTextField()
        package let cvcField = CVCTextField()
        package let payButton = MollieStyledPayButton()

        /// Grouped container that owns the rounded border + dividers around
        /// the four fields. Created in `installLayout()`; surfaced as `package`
        /// so `MollieAppearanceApplier` can re-theme it without reaching
        /// into the view hierarchy.
        package private(set) var groupedFormView: MollieGroupedCardFormView?

        /// All four custom field subclasses in display order. Surfaced so the
        /// theme applier can iterate without re-listing names.
        package var cardFields: [UITextField] {
            [cardholderField, cardNumberField, expiryField, cvcField]
        }

        /// Best-effort network reconciliation for the trailing brand icon.
        /// `BINPrefixTable` (via `updateBrand(forPAN:)`) is the instant-UX
        /// authority and needs no network dependency at all; this optional
        /// service, when supplied, confirms or corrects that local guess
        /// once its lookup resolves (e.g. Cartes Bancaires, which co-badges
        /// onto Visa/Mastercard BINs and can never be detected locally —
        /// see `BINPrefixTable`'s doc comment). Defaults to
        /// `nil` so the form works fully offline with zero behaviour change
        /// for callers that don't inject one. The IIN lookup network host
        /// is not yet confirmed — callers should only inject a service once
        /// that's resolved.
        private let iinLookupService: IINLookupService?

        /// Locale-specific `.lproj` sub-bundle resolved once at init from
        /// the caller's `locale`, via `MolliePaymentsUIBundleLocator
        /// .localizedBundle(for:)`. Threaded into every localized-string
        /// call site (fields, section labels, pay button, validation
        /// messages) instead of relying on `NSLocalizedString`'s default
        /// system-preferred-language selection, so a merchant-supplied
        /// locale override (`MollieCheckout(locale:)`) actually changes
        /// what the form displays even when it doesn't match the device's
        /// preferred languages.
        private let localizedBundle: Bundle

        package init(
            theme: MollieAppearance = MollieAppearance(),
            locale: Locale = .current,
            iinLookupService: IINLookupService? = nil
        ) {
            self.theme = theme
            self.iinLookupService = iinLookupService
            localizedBundle = MolliePaymentsUIBundleLocator.localizedBundle(for: locale)
            super.init(nibName: nil, bundle: nil)
            applyLocalizedBundleToFields()
        }

        /// Injects `localizedBundle` into the four field subclasses. Must
        /// run AFTER `super.init()` — the fields already exist as
        /// eagerly-initialized stored properties by then, but touching
        /// `self.cardholderField` etc. before `super.init()` returns is not
        /// allowed.
        private func applyLocalizedBundleToFields() {
            cardholderField.localizedBundle = localizedBundle
            cardNumberField.localizedBundle = localizedBundle
            expiryField.localizedBundle = localizedBundle
            cvcField.localizedBundle = localizedBundle
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
            // Applied here (not just on `viewWillAppear`) because SwiftUI's
            // embedded path measures `sizeThatFits` by forcing the view to
            // load — which runs this method — but never triggers
            // `viewWillAppear` before freezing the container to that
            // measured height. Deferring the theme meant that measurement
            // used the un-themed (default-init) field heights, so the later,
            // taller themed layout got squeezed into a too-small frame and
            // the section header labels were compressed to zero height.
            // `theme` is immutable once set, so applying it now (rather than
            // "late") changes nothing about the final visual state.
            MollieAppearanceApplier.apply(theme, to: self)
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
            // Theme is applied in viewDidLoad (see comment there); no need
            // to re-apply here. `traitCollectionDidChange` handles the
            // dark-mode-switch-mid-flow recolour case.
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
            MollieAppearanceApplier.apply(theme, to: self)
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
            grouped.applyLocalizedBundle(localizedBundle)
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
            // No outer insets here — the host owns the margins around the
            // component (full-bleed layout). Pinned to the safe area, not
            // arbitrary padding, so content still clears notches/home
            // indicators when the host gives the VC the full screen.
            NSLayoutConstraint.activate([
                stack.topAnchor.constraint(equalTo: guide.topAnchor),
                stack.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
                // Bottom constraint is `lessThanOrEqual` so the modal sheet
                // path (where the VC owns the full screen) still leaves
                // empty space below the form, while the embedded path
                // (where this VC is wrapped in a `UIViewControllerRepresentable`)
                // gets a finite intrinsic content size from
                // `systemLayoutSizeFitting` instead of stretching forever.
                stack.bottomAnchor.constraint(lessThanOrEqualTo: guide.bottomAnchor),
            ])
        }

        private func configureSubmit() {
            payButton.setTitle(
                MollieLocalizedString(
                    "form.payButton.title",
                    bundle: localizedBundle,
                    comment: "Title of the primary call-to-action button that submits the card form."
                )
            )
            payButton.onTap = { [weak self] in self?.handleSubmit() }
            // Re-evaluate validity on every keystroke, and clear (never
            // introduce) a field's caption once its value becomes valid.
            // Blur (`editingDidEnd`) is what introduces a caption — see
            // `validateAndDisplayField(_:)` — matching the Web SDK's
            // show-on-blur timing.
            for field in cardFields {
                field.addTarget(self, action: #selector(handleFieldEditingChanged(_:)), for: .editingChanged)
                field.addTarget(self, action: #selector(handleFieldEditingDidEnd(_:)), for: .editingDidEnd)
            }
            // Brand detection only cares about the PAN field.
            cardNumberField.addTarget(self, action: #selector(handleCardNumberChanged), for: .editingChanged)
        }

        @objc private func handleCardNumberChanged() {
            updateBrand(forPAN: cardNumberField.text ?? "")
        }

        @objc private func handleFieldEditingChanged(_ sender: UITextField) {
            updateSubmitState()
            guard let field = cardField(for: sender) else { return }
            clearFieldErrorIfResolved(field)
            fireFieldEvent(for: field)
        }

        @objc private func handleFieldEditingDidEnd(_ sender: UITextField) {
            guard let field = cardField(for: sender) else { return }
            validateAndDisplayField(field)
            fireFieldEvent(for: field)
        }

        /// Current validation error for a single field, if any — same
        /// source as `currentFieldErrors()` but keeps the typed
        /// `ValidationError` (rather than its `userMessage`) so
        /// `fireFieldEvent(for:)` can hand it straight to
        /// `CardFieldEvent`.
        private func currentValidationError(for field: CardField) -> CardFormValidator.ValidationError? {
            CardFormValidator.validateAll(snapshot: currentSnapshot()).first { $0.fieldKind == field }
        }

        /// Notify `onFieldEvent` with `field`'s live validity/error, plus
        /// whichever scheme the card-number field currently detects — every
        /// field's event carries the detected scheme (not just `.pan`'s) so
        /// a host doesn't need to separately track the PAN field just to
        /// read it. Called from both the per-keystroke
        /// (`handleFieldEditingChanged`) and blur (`handleFieldEditingDidEnd`)
        /// paths. `package` access lets tests drive it directly — the same
        /// reason `validateAndDisplayField(_:)`/`clearFieldErrorIfResolved(_:)`
        /// are `package`: `sendActions(for:)` doesn't reliably fire
        /// target-action in this repo's headless UIKit test harness.
        package func fireFieldEvent(for field: CardField) {
            let error = currentValidationError(for: field)
            let scheme = Self.detectedPrimaryScheme(forPAN: cardNumberField.text ?? "")
            onFieldEvent?(CardFieldEvent(field: field, isValid: error == nil, error: error, detectedScheme: scheme))
        }

        private func cardField(for textField: UITextField) -> CardField? {
            if textField === cardholderField {
                return .cardholder
            }
            if textField === cardNumberField {
                return .pan
            }
            if textField === expiryField {
                return .expiry
            }
            if textField === cvcField {
                return .cvc
            }
            return nil
        }

        // MARK: - Brand detection

        /// Pure, directly-callable detection seam: leading digits of `pan`
        /// through `BINPrefixTable` -> a single primary scheme via
        /// `CardScheme.primary(from:)` (the shared priority-collapse logic
        /// also used by `CardNumberTextField`'s grouping/cap). Synchronous
        /// and needs no network — this is what makes the brand icon update
        /// on every keystroke. PCI: only the leading 8 digits are ever
        /// read; the full PAN is never inspected or logged.
        package static func detectedPrimaryScheme(forPAN pan: String) -> CardScheme? {
            let digits = CardNumberTextField.digitsOnly(pan)
            let prefix = String(digits.prefix(8))
            return CardScheme.primary(from: BINPrefixTable.detect(prefix: prefix))
        }

        /// Whether a network reconciliation response requested for
        /// `requestedPrefix` still applies to what's currently typed. Once
        /// the user has changed the PAN so its current digit-prefix no
        /// longer starts with `requestedPrefix`, the response is stale and
        /// must be discarded rather than clobbering a newer local guess.
        package static func isReconcileStillApplicable(requestedPrefix: String, currentPAN: String) -> Bool {
            CardNumberTextField.digitsOnly(currentPAN).hasPrefix(requestedPrefix)
        }

        /// Testable wiring seam for live brand detection (`sendActions(for:
        /// .editingChanged)` doesn't reliably drive target-action in this
        /// repo's headless UIKit test harness, so tests call this directly
        /// instead of the field's real editing-changed handler).
        ///
        /// Applies the local, synchronous `BINPrefixTable` guess
        /// immediately — this never waits on the network — then kicks an
        /// optional, best-effort reconciliation via `iinLookupService` if
        /// one was injected.
        package func updateBrand(forPAN pan: String) {
            lastKnownPANForBrandDetection = pan
            groupedFormView?.updateCardBrand(Self.detectedPrimaryScheme(forPAN: pan))
            reconcileBrandViaNetwork(pan: pan)
        }

        /// The PAN as of the most recent `updateBrand(forPAN:)` call.
        /// Read back by the in-flight reconcile to decide whether its
        /// response is stale — deliberately not `cardNumberField.text`,
        /// since `updateBrand(forPAN:)` is the testable seam callers (and
        /// tests) drive directly, and it may run without ever touching the
        /// live text field.
        private var lastKnownPANForBrandDetection = ""

        /// Task backing the in-flight network reconciliation kicked off by
        /// `updateBrand(forPAN:)`, if any. Cancelled on every subsequent
        /// call so a fast typist never lets an older reconcile race a
        /// newer one.
        private var iinReconcileTask: Task<Void, Never>?

        private func reconcileBrandViaNetwork(pan: String) {
            iinReconcileTask?.cancel()
            guard let iinLookupService else { return }
            let prefix = String(CardNumberTextField.digitsOnly(pan).prefix(8))
            // `IINLookupService.lookup(prefix:)` already no-ops under 6
            // digits, but checking here too avoids spinning up a Task (and
            // its actor hop) for every keystroke on a short PAN.
            guard prefix.count >= 6 else { return }
            iinReconcileTask = Task { [weak self] in
                guard let self else { return }
                guard let result = await iinLookupService.lookup(prefix: prefix) else { return }
                guard !Task.isCancelled else { return }
                guard Self.isReconcileStillApplicable(
                    requestedPrefix: prefix,
                    currentPAN: lastKnownPANForBrandDetection
                ) else { return }
                guard let confirmed = CardScheme.primary(from: result.schemes) else { return }
                groupedFormView?.updateCardBrand(confirmed)
            }
        }

        /// Test-only: await the in-flight network reconciliation kicked off
        /// by the most recent `updateBrand(forPAN:)` call, if any.
        /// Production code never awaits this — the entire point of the
        /// optional network reconcile is that it never blocks the UI.
        /// `package` access keeps this invisible outside the SPM package.
        package func waitForPendingIINReconcileForTesting() async {
            await iinReconcileTask?.value
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

        // MARK: - Per-field validation UX (Phase B3)

        /// Every currently-failing field mapped to its user-facing message.
        /// Shared by the blur and per-keystroke paths below so neither one
        /// re-derives `CardFormValidator`'s field-error rules itself.
        private func currentFieldErrors() -> [CardField: String] {
            Dictionary(
                uniqueKeysWithValues: CardFormValidator.validateAll(snapshot: currentSnapshot())
                    .map { ($0.fieldKind, $0.userMessage(bundle: localizedBundle)) }
            )
        }

        /// Captions currently shown below the four fields, keyed by field.
        /// Source of truth for merging partial updates — blur validates one
        /// field, a keystroke clears one field — so neither write clobbers
        /// what's displayed for the other three.
        private var displayedFieldErrors: [CardField: String] = [:]

        private func setFieldError(_ field: CardField, message: String?) {
            if let message {
                displayedFieldErrors[field] = message
            } else {
                displayedFieldErrors.removeValue(forKey: field)
            }
            groupedFormView?.showFieldErrors(displayedFieldErrors)
        }

        /// Posted to VoiceOver after a failed submit, summarizing every
        /// current problem. Wrapped as an injectable seam — the real
        /// `UIAccessibility.post` API doesn't record what it was passed, so
        /// tests substitute this to assert on the announced string instead.
        /// `package` access keeps it invisible outside the SPM package.
        package var accessibilityAnnouncer: (String) -> Void = { message in
            UIAccessibility.post(notification: .announcement, argument: message)
        }

        private func announcementSummary(for errors: [CardFormValidator.ValidationError]) -> String {
            errors.map { $0.userMessage(bundle: localizedBundle) }.joined(separator: " ")
        }

        /// Submit-time validation. Unlike the live submit-button gate
        /// (`updateSubmitState`, which only needs the *first* failure to
        /// know whether to disable the button), this surfaces every failing
        /// field's caption at once — the Web SDK's submit-time UX. On
        /// failure it also focuses the first invalid field and posts a
        /// VoiceOver summary of every problem. Factored out from
        /// `handleSubmit` so tests can drive it directly without
        /// `sendActions`, which doesn't reliably fire target-action in this
        /// repo's headless UIKit test harness. `package` access keeps it
        /// invisible outside the SPM package.
        @discardableResult
        package func validateAndDisplayAll() -> Bool {
            let errors = CardFormValidator.validateAll(snapshot: currentSnapshot())
            displayedFieldErrors = Dictionary(
                uniqueKeysWithValues: errors.map { ($0.fieldKind, $0.userMessage(bundle: localizedBundle)) }
            )
            groupedFormView?.showFieldErrors(displayedFieldErrors)
            guard let firstError = errors.first else { return true }
            focusField(for: firstError)
            accessibilityAnnouncer(announcementSummary(for: errors))
            return false
        }

        /// Blur-time validation (`editingDidEnd`): shows or clears exactly
        /// one field's caption, leaving the other three untouched. This is
        /// what *introduces* a caption — the per-keystroke path
        /// (`clearFieldErrorIfResolved(_:)`) only ever clears one once it
        /// resolves, matching the Web SDK's show-on-blur timing. Factored
        /// out from the `editingDidEnd` target-action for the same
        /// testability reason as `validateAndDisplayAll()`. `package`
        /// access keeps it invisible outside the SPM package.
        package func validateAndDisplayField(_ field: CardField) {
            setFieldError(field, message: currentFieldErrors()[field])
        }

        /// Per-keystroke seam (`editingChanged`): clears a field's caption
        /// once its value becomes valid. Never shows a *new* error here —
        /// only `validateAndDisplayField(_:)` (blur) or
        /// `validateAndDisplayAll()` (submit) are allowed to introduce one.
        /// `package` access keeps it invisible outside the SPM package.
        package func clearFieldErrorIfResolved(_ field: CardField) {
            guard displayedFieldErrors[field] != nil, currentFieldErrors()[field] == nil else { return }
            setFieldError(field, message: nil)
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
            guard validateAndDisplayAll() else {
                updateSubmitState()
                return
            }
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
