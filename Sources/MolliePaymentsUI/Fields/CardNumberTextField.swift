#if canImport(UIKit)
    import MolliePayments
    import UIKit

    /// PAN field with iOS-16-safe content type, cursor-stable masking, and
    /// Luhn validation.
    package final class CardNumberTextField: UITextField {
        override init(frame: CGRect) {
            super.init(frame: frame)
            configure()
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("CardNumberTextField does not support NSCoder")
        }

        /// Locale-specific `.lproj` sub-bundle resolved by
        /// `MollieCardFormViewController` from the merchant's (possibly
        /// overridden) locale. See `CardholderTextField.localizedBundle`
        /// for the full rationale.
        package var localizedBundle: Bundle? {
            didSet {
                placeholder = MollieLocalizedString(
                    "card.number.placeholder",
                    bundle: localizedBundle,
                    comment: "Placeholder for the card-number field, showing the expected digit grouping."
                )
            }
        }

        private func configure() {
            placeholder = MollieLocalizedString(
                "card.number.placeholder",
                comment: "Placeholder for the card-number field, showing the expected digit grouping."
            )
            keyboardType = .numberPad
            autocorrectionType = .no
            spellCheckingType = .no
            // Smart-substitution hardening: number pad already blocks most
            // of this, but a paste path can still inject smart punctuation
            // / dictation suggestions that the tokeniser would reject.
            smartInsertDeleteType = .no
            smartDashesType = .no
            smartQuotesType = .no
            // `creditCardNumber` is iOS 10+; the richer iOS-17 content types
            // (creditCardExpiration / creditCardSecurityCode) intentionally
            // omitted to keep the iOS 16 floor in Package.swift honest.
            textContentType = .creditCardNumber
            // Deliberately NOT `isSecureTextEntry`. Matches industry-standard
            // card-entry UIs and the Mollie Web SDK: users must
            // see the digits they type, or typos drive retries (which
            // re-expose the PAN more than a screen recorder ever would).
            // The remaining defences below still hold — dictation /
            // QuickType / autofill caches are disabled, accessibility
            // value is masked, copy/cut are blocked, and the field is
            // wiped on submit + `viewWillDisappear`.
            // Strip non-digits on every edit. `.numberPad` only hides the
            // letter keys on the on-screen keyboard — hardware keyboards
            // (simulator, iPad, Mac Catalyst), paste, and dictation can
            // still inject anything. Without this, a tokeniser call would
            // 400 on `4242abc4242...` instead of failing politely in-form.
            addTarget(self, action: #selector(sanitize), for: .editingChanged)
        }

        /// Strip every character that isn't an ASCII digit. Mirrors the
        /// ASCII-only guard that `ExpiryParser` already enforces — pasted
        /// Arabic-Indic numerals satisfy `Character.isNumber` but the
        /// tokeniser only accepts `[0-9]`, so letting them through here
        /// would silently fail the network call.
        package static func digitsOnly(_ raw: String) -> String {
            raw.filter { $0.isASCII && $0.isNumber }
        }

        /// Local, synchronous scheme guess from the field's own digits —
        /// only ever reads the leading 8 digits (PCI: never the full PAN).
        /// Delegates the Set -> single-scheme collapse to
        /// `CardScheme.primary(from:)`, the single home for that priority
        /// order shared with `MollieCardFormViewController`'s brand icon.
        private static func primaryScheme(forDigits digits: String) -> CardScheme? {
            let prefix = String(digits.prefix(8))
            let schemes = BINPrefixTable.detect(prefix: prefix)
            return CardScheme.primary(from: schemes)
        }

        /// Per-brand PAN length. Amex is fixed at 15; every other scheme
        /// (including Diners, which is fixed at 14 but co-badges into
        /// longer ranges in practice) caps at 19 — the PCI upper bound for
        /// issuer-assigned PANs and the same ceiling `CardFormValidator`
        /// enforces. A tighter per-brand cap here would silently truncate
        /// digits off a valid long or co-badged PAN before the validator
        /// ever saw them, failing Luhn with a misleading "too short"/
        /// "check for typos" error instead of the field just accepting
        /// what the user typed.
        private static func maxDigits(for scheme: CardScheme?) -> Int {
            switch scheme {
            case .amex: 15
            default: 19
            }
        }

        /// Inserts a single space after each group. `sizes` sums to (at
        /// most) `digits.count`; a shorter `digits` simply stops early so
        /// partial input formats correctly while still typing.
        private static func chunk(_ digits: String, sizes: [Int]) -> String {
            var result = ""
            var index = digits.startIndex
            for size in sizes {
                guard index < digits.endIndex else { break }
                let end = digits.index(index, offsetBy: size, limitedBy: digits.endIndex) ?? digits.endIndex
                if !result.isEmpty {
                    result += " "
                }
                result += digits[index ..< end]
                index = end
            }
            return result
        }

        /// Groups of 4 for every scheme without a bespoke layout (Visa,
        /// Mastercard, Maestro, Discover, Diners Club, JCB, UnionPay, Cartes
        /// Bancaires, unrecognised prefixes). Diners' 4-6-4 layout only sums
        /// to 14 digits, so it can't represent the 16-19 digit co-badged
        /// PANs the 19-digit cap now allows through; grouping is cosmetic
        /// (unlike the cap, which is the correctness issue), so Diners
        /// falls back to the same groups-of-4 layout as everything else.
        private static func chunkByFour(_ digits: String) -> String {
            chunk(digits, sizes: Array(repeating: 4, count: (digits.count + 3) / 4))
        }

        /// Strips non-digits, hard-caps at the detected brand's PAN length,
        /// then live-groups with brand-appropriate separators: Amex 4-6-5,
        /// everything else 4-4-4-4(-…). The brand comes from this field's
        /// own digits via `BINPrefixTable.detect` — same local, synchronous,
        /// offline detection `MollieCardFormViewController` uses for the
        /// brand icon, so the grouping never waits on a network round-trip.
        package static func format(_ raw: String) -> String {
            let digits = digitsOnly(raw)
            let scheme = primaryScheme(forDigits: digits)
            let limited = String(digits.prefix(maxDigits(for: scheme)))
            switch scheme {
            case .amex:
                return chunk(limited, sizes: [4, 6, 5])
            default:
                return chunkByFour(limited)
            }
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

        /// Block the system text-edit menu actions that would copy the
        /// typed PAN to the system pasteboard — which is process-global on
        /// iOS and readable by any other foregrounded app. Underscore-
        /// prefixed selectors are private system actions; blocking them
        /// covers the "Share…", "Look Up", "Translate" entries that ship
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

        /// Mask all but the last four PAN digits for VoiceOver / Switch-
        /// Control, matching the PCI display-rule (`storage` is moot here —
        /// the tokeniser swallows the full PAN — but the spoken value still
        /// needs the truncation). Behaves like a card present prompt.
        override package var accessibilityValue: String? {
            get {
                let raw = text ?? ""
                let trailing = raw.suffix(4)
                let maskCount = max(0, raw.count - trailing.count)
                return String(repeating: "•", count: maskCount) + String(trailing)
            }
            set { super.accessibilityValue = newValue }
        }

        /// Reserve 28pt of trailing padding so the typed PAN never slides
        /// under the brand icon pinned 8pt from the row's trailing edge
        /// inside `MollieGroupedCardFormView`. Editing + display rects
        /// stay in lockstep so the caret never jumps when focus changes.
        override package func textRect(forBounds bounds: CGRect) -> CGRect {
            super.textRect(forBounds: bounds).inset(by: UIEdgeInsets(top: 0, left: 0, bottom: 0, right: 28))
        }

        override package func editingRect(forBounds bounds: CGRect) -> CGRect {
            super.editingRect(forBounds: bounds).inset(by: UIEdgeInsets(top: 0, left: 0, bottom: 0, right: 28))
        }
    }
#endif
