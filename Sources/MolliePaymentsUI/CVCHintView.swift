#if canImport(UIKit)
    import UIKit

    /// Trailing accessory inside the CVC row that hints at where the
    /// security code lives on the back of the card. Mirrors the Web SDK's
    /// little card-back graphic: a thin rounded rect with a darker top
    /// "magnetic stripe" band and the "123" digits below it.
    ///
    /// Purely drawn from `UIView` + `CALayer` so no asset shipping is
    /// required. Colours come from `applyTheme(_:)` so a dark merchant
    /// palette stays readable.
    package final class CVCHintView: UIView {
        private let stripeLayer = CALayer()
        private let digitsLabel: UILabel = {
            let label = UILabel()
            label.text = "123"
            label.textAlignment = .center
            label.font = .monospacedDigitSystemFont(ofSize: 9, weight: .semibold)
            label.translatesAutoresizingMaskIntoConstraints = false
            return label
        }()

        package init() {
            super.init(frame: .zero)
            translatesAutoresizingMaskIntoConstraints = false
            layer.borderWidth = 1
            layer.cornerRadius = 3
            layer.masksToBounds = true
            layer.addSublayer(stripeLayer)
            addSubview(digitsLabel)

            NSLayoutConstraint.activate([
                widthAnchor.constraint(equalToConstant: 36),
                heightAnchor.constraint(equalToConstant: 22),
                digitsLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
                digitsLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            ])
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("CVCHintView does not support NSCoder")
        }

        override package func layoutSubviews() {
            super.layoutSubviews()
            // Top "magnetic stripe": full-width band, ~5pt tall, anchored
            // to the top of the rect. Recomputed in layoutSubviews so the
            // stripe tracks bounds changes (e.g. Dynamic Type resizing
            // the row that hosts this view).
            stripeLayer.frame = CGRect(
                x: 0,
                y: 4,
                width: bounds.width,
                height: 5
            )
        }

        /// Theme-driven recolour. Border + stripe use the same colour as
        /// the field border so the hint reads as part of the form chrome
        /// (not as an interactive element); the digit label uses the
        /// text colour at 60% alpha so it stays a hint, not a focus.
        package func applyTheme(_ theme: MollieAppearance) {
            let chrome = theme.colors.fieldBorder.uiColor
            layer.borderColor = chrome.cgColor
            stripeLayer.backgroundColor = chrome.cgColor
            digitsLabel.textColor = theme.colors.text.uiColor.withAlphaComponent(0.6)
            backgroundColor = theme.colors.field.uiColor
        }
    }
#endif
