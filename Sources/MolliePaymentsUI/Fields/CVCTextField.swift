#if canImport(UIKit)
    import UIKit

    /// CVC field with scheme-aware length validation (3 for Visa/MC, 4 for
    /// Amex, fallback 4 on stale).
    package final class CVCTextField: UITextField {
        override init(frame: CGRect) {
            super.init(frame: frame)
            configure()
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("CVCTextField does not support NSCoder")
        }

        /// Locale-specific `.lproj` sub-bundle resolved by
        /// `MollieCardFormViewController` from the merchant's (possibly
        /// overridden) locale. See `CardholderTextField.localizedBundle`
        /// for the full rationale. Also feeds `accessibilityLabel`, which
        /// re-resolves on every access rather than caching.
        package var localizedBundle: Bundle? {
            didSet {
                placeholder = MollieLocalizedString(
                    "card.cvc.placeholder",
                    bundle: localizedBundle,
                    comment: "Placeholder for the card-security-code (CVC/CVV) field."
                )
            }
        }

        private func configure() {
            placeholder = MollieLocalizedString(
                "card.cvc.placeholder",
                comment: "Placeholder for the card-security-code (CVC/CVV) field."
            )
            keyboardType = .numberPad
            autocorrectionType = .no
            spellCheckingType = .no
            // Deliberately NOT `isSecureTextEntry`. Same reasoning as the
            // PAN field: matches industry SDKs + Mollie Web SDK, and the
            // user needs to verify a 3- or 4-digit code they typically
            // read off the back of the card. Other defences (no
            // dictation / QuickType cache, masked accessibilityValue,
            // copy/cut blocked, lifecycle wipes) remain in place.
            smartInsertDeleteType = .no
            smartDashesType = .no
            smartQuotesType = .no
            // Same rationale as the PAN field: `.numberPad` only hides
            // letter keys on the on-screen keyboard. Hardware keyboards,
            // paste, and dictation can still inject anything.
            addTarget(self, action: #selector(sanitize), for: .editingChanged)
        }

        /// Strip every character that isn't an ASCII digit.
        package static func digitsOnly(_ raw: String) -> String {
            raw.filter { $0.isASCII && $0.isNumber }
        }

        /// Strips non-digits and hard-caps at 4 — the longest CVC any
        /// scheme issues (Amex). No scheme needs fewer than 3, so a fixed
        /// cap (rather than brand-aware length like the PAN field) is
        /// enough: the field never blocks a valid 3-digit entry, it just
        /// refuses a 5th digit.
        package static func format(_ raw: String) -> String {
            String(digitsOnly(raw).prefix(4))
        }

        @objc private func sanitize() {
            let raw = text ?? ""
            let formatted = Self.format(raw)
            guard formatted != raw else { return }
            text = formatted
            if let endRange = textRange(from: endOfDocument, to: endOfDocument) {
                selectedTextRange = endRange
            }
        }

        /// VoiceOver/Switch-Control read the literal `text` by default,
        /// which would speak the CVC aloud in earshot of the user's
        /// surroundings. Mask each character so the secure-entry promise
        /// holds for assistive tech as well as visible chrome.
        override package var accessibilityValue: String? {
            get { String(repeating: "•", count: text?.count ?? 0) }
            set { super.accessibilityValue = newValue }
        }

        /// Override the label so the spoken label is a clear, human-readable
        /// name for the field rather than the raw "CVC" placeholder. The
        /// field deliberately does NOT use `isSecureTextEntry` (masking is
        /// applied via `accessibilityValue` above instead), so the label
        /// must not claim "secure entry" — that would misrepresent how the
        /// field actually behaves to assistive tech users.
        override package var accessibilityLabel: String? {
            get {
                MollieLocalizedString(
                    "card.cvc.accessibilityLabel",
                    bundle: localizedBundle,
                    comment: "Accessibility label for the CVC field."
                )
            }
            set { super.accessibilityLabel = newValue }
        }

        /// Reserve 44pt of trailing padding so the typed CVC never slides
        /// under the `CVCHintView` accessory pinned to the trailing edge of
        /// the CVC half of the form's expiry/CVC row. The hint is 36pt wide
        /// with an 8pt trailing margin; 44pt keeps the caret clear at any
        /// Dynamic Type size.
        override package func textRect(forBounds bounds: CGRect) -> CGRect {
            super.textRect(forBounds: bounds).inset(by: UIEdgeInsets(top: 0, left: 0, bottom: 0, right: 44))
        }

        override package func editingRect(forBounds bounds: CGRect) -> CGRect {
            super.editingRect(forBounds: bounds).inset(by: UIEdgeInsets(top: 0, left: 0, bottom: 0, right: 44))
        }

        /// Block the system text-edit menu actions that would copy the
        /// typed CVC to the system pasteboard — which is process-global on
        /// iOS and readable by any other foregrounded app. Mirrors the
        /// guard on `CardNumberTextField`; underscore-prefixed selectors
        /// cover the "Share…", "Look Up", "Translate" entries that ship
        /// new menu items across iOS versions.
        override package func canPerformAction(
            _ action: Selector,
            withSender sender: Any?
        ) -> Bool {
            switch action {
            case #selector(copy(_:)),
                 #selector(cut(_:)),
                 Selector("_share:"),
                 Selector("_define:"),
                 Selector("_translate:"):
                false
            default:
                super.canPerformAction(action, withSender: sender)
            }
        }
    }
#endif
