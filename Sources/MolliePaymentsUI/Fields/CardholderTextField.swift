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

        private func configure() {
            placeholder = "Full name on card"
            autocapitalizationType = .words
            autocorrectionType = .no
            spellCheckingType = .no
            textContentType = .name
            returnKeyType = .next
        }
    }
#endif
