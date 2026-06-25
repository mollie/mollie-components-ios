#if canImport(UIKit)
    import UIKit

    /// MM/YY expiry field. Auto-inserts the `/` separator so the user only
    /// has to type four digits on the number-pad keyboard — which has no
    /// `/` key, so without auto-formatting the user is stuck the moment
    /// they finish the month half.
    package final class ExpiryDateTextField: UITextField {
        override init(frame: CGRect) {
            super.init(frame: frame)
            configure()
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("ExpiryDateTextField does not support NSCoder")
        }

        private func configure() {
            placeholder = "MM/YY"
            keyboardType = .numberPad
            autocorrectionType = .no
            spellCheckingType = .no
            // Pure-function formatter is invoked on every user edit. Targets
            // fire in registration order, so this runs *before* any host-
            // attached `editingChanged` (e.g. the form VC's validity check)
            // — by the time the host sees the change, the slash is in place.
            addTarget(self, action: #selector(autoFormat), for: .editingChanged)
        }

        /// Strip non-digits, cap at four digits, insert `/` after the month
        /// half. Idempotent: feeding the output back through returns the
        /// same string, so paste paths that already contain `/` (`12/30`,
        /// `12 / 30`) collapse to the canonical form without flicker.
        package static func format(_ raw: String) -> String {
            let digits = raw.filter { $0.isASCII && $0.isNumber }
            let limited = String(digits.prefix(4))
            guard limited.count > 2 else { return limited }
            let monthEnd = limited.index(limited.startIndex, offsetBy: 2)
            return limited[..<monthEnd] + "/" + limited[monthEnd...]
        }

        @objc private func autoFormat() {
            let raw = text ?? ""
            let formatted = Self.format(raw)
            guard formatted != raw else { return }
            text = formatted
            // Pin the caret to the end after a reformat. Mid-string edits
            // on a four-digit field are rare enough that anchoring beats
            // a more complex offset-preservation scheme; industry-standard
            // card-entry UIs all do the same.
            if let endRange = textRange(from: endOfDocument, to: endOfDocument) {
                selectedTextRange = endRange
            }
        }
    }
#endif
