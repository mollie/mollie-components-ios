#if canImport(UIKit)
    import UIKit

    /// Cardholder-name field. Thin subclass so validation can be attached
    /// without churning the form-controller code.
    package final class CardholderTextField: UITextField {
        override init(frame: CGRect) {
            super.init(frame: frame)
            configure()
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("CardholderTextField does not support NSCoder")
        }

        /// Locale-specific `.lproj` sub-bundle resolved by
        /// `MollieCardFormViewController` from the merchant's (possibly
        /// overridden) locale. `nil` keeps the default system-preferred-
        /// language behaviour. Re-applies the placeholder on every set so
        /// the VC can inject the resolved bundle after this field has
        /// already been constructed with its default English text.
        package var localizedBundle: Bundle? {
            didSet {
                placeholder = MollieLocalizedString(
                    "card.holder.placeholder",
                    bundle: localizedBundle,
                    comment: "Placeholder for the cardholder-name field."
                )
            }
        }

        private func configure() {
            placeholder = MollieLocalizedString(
                "card.holder.placeholder",
                comment: "Placeholder for the cardholder-name field."
            )
            autocapitalizationType = .words
            autocorrectionType = .no
            spellCheckingType = .no
            textContentType = .name
            returnKeyType = .next
        }
    }
#endif
