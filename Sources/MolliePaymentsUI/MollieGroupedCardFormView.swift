#if canImport(UIKit)
    import MolliePayments
    import UIKit

    /// Grouped container that arranges the four card-form text fields
    /// into two labelled sections — "Card information" (number + expiry +
    /// CVC) and "Card holder" (name) — each inside its own rounded border.
    /// Mirrors the Web SDK's card-component layout so the iOS sheet reads
    /// as the same product surface.
    ///
    /// The view does not create the text fields — callers (today the
    /// `MollieCardFormViewController`) pass them in so any field-level
    /// configuration (placeholders, content types, masking, validation
    /// hooks) remains where it already lives. This keeps the grouped view
    /// focused on layout + chrome, and avoids duplicating the field wiring.
    package final class MollieGroupedCardFormView: UIView {
        package let cardNumberField: CardNumberTextField
        package let expiryField: ExpiryDateTextField
        package let cvcField: CVCTextField
        package let cardholderField: CardholderTextField

        /// Brand mark pinned to the trailing edge of the card-number row.
        /// Shows a generic card placeholder by default; `updateCardBrand(_:)`
        /// cross-fades it to a resolved brand once the IIN lookup lands.
        /// Reserves a fixed 24x16 slot so the row layout doesn't shift
        /// when the brand swaps.
        package let brandIconView = CardBrandIconView()

        /// Card-back hint accessory pinned to the trailing edge of the CVC
        /// half of the expiry/CVC row. Visual nudge toward where the
        /// security code lives on the physical card.
        package let cvcHintView = CVCHintView()

        /// Section header above the "Card information" group.
        private let cardInfoLabel: UILabel = {
            let label = UILabel()
            label.text = "Card information"
            label.adjustsFontForContentSizeCategory = true
            label.translatesAutoresizingMaskIntoConstraints = false
            return label
        }()

        /// Section header above the "Card holder" group.
        private let cardHolderLabel: UILabel = {
            let label = UILabel()
            label.text = "Card holder"
            label.adjustsFontForContentSizeCategory = true
            label.translatesAutoresizingMaskIntoConstraints = false
            return label
        }()

        /// Visual container for the number + expiry + CVC rows. Kept
        /// separate from `self` so the error label can sit below the
        /// border without being clipped by `clipsToBounds`.
        private let cardInfoBorderView = UIView()
        /// Visual container for the cardholder row.
        private let cardHolderBorderView = UIView()
        /// Hairline between the card-number row and the expiry/CVC row,
        /// inside the card-information container.
        private let divider1 = UIView()

        private let errorLabel: UILabel = {
            let label = UILabel()
            // Use a Dynamic Type style so the inline validation message
            // scales with the user's preferred content size. The earlier
            // fixed `.systemFont(ofSize: 12)` ignored accessibility text
            // sizing and shipped a regression versus the rest of the form.
            label.font = .preferredFont(forTextStyle: .caption1)
            label.adjustsFontForContentSizeCategory = true
            label.numberOfLines = 0
            label.isHidden = true
            label.translatesAutoresizingMaskIntoConstraints = false
            return label
        }()

        package init(
            cardNumberField: CardNumberTextField,
            expiryField: ExpiryDateTextField,
            cvcField: CVCTextField,
            cardholderField: CardholderTextField
        ) {
            self.cardNumberField = cardNumberField
            self.expiryField = expiryField
            self.cvcField = cvcField
            self.cardholderField = cardholderField
            super.init(frame: .zero)
            setupLayout()
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("MollieGroupedCardFormView does not support NSCoder")
        }

        private func setupLayout() {
            translatesAutoresizingMaskIntoConstraints = false

            for border in [cardInfoBorderView, cardHolderBorderView] {
                border.translatesAutoresizingMaskIntoConstraints = false
                border.layer.borderWidth = 1
                border.clipsToBounds = true
                addSubview(border)
            }

            // Strip any borders coming from the field subclasses; the grouped
            // containers own the visible chrome now.
            for item in [cardNumberField, expiryField, cvcField, cardholderField] {
                item.borderStyle = .none
                item.translatesAutoresizingMaskIntoConstraints = false
            }

            divider1.translatesAutoresizingMaskIntoConstraints = false
            cardInfoBorderView.addSubview(divider1)
            cardInfoBorderView.addSubview(cardNumberField)
            cardInfoBorderView.addSubview(brandIconView)

            let expiryCVCStack = UIStackView(arrangedSubviews: [expiryField, cvcField])
            expiryCVCStack.axis = .horizontal
            expiryCVCStack.distribution = .fillEqually
            expiryCVCStack.translatesAutoresizingMaskIntoConstraints = false
            cardInfoBorderView.addSubview(expiryCVCStack)
            // CVC hint sits on top of the CVC field cell, pinned to its
            // trailing edge. CVC field reserves matching trailing padding
            // in `textRect/editingRect` so the typed code never slides
            // under the hint.
            cardInfoBorderView.addSubview(cvcHintView)

            cardHolderBorderView.addSubview(cardholderField)

            addSubview(cardInfoLabel)
            addSubview(cardHolderLabel)
            addSubview(errorLabel)

            NSLayoutConstraint.activate([
                // Card information section
                cardInfoLabel.topAnchor.constraint(equalTo: topAnchor),
                cardInfoLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
                cardInfoLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),

                cardInfoBorderView.topAnchor.constraint(equalTo: cardInfoLabel.bottomAnchor, constant: 8),
                cardInfoBorderView.leadingAnchor.constraint(equalTo: leadingAnchor),
                cardInfoBorderView.trailingAnchor.constraint(equalTo: trailingAnchor),

                cardNumberField.topAnchor.constraint(equalTo: cardInfoBorderView.topAnchor),
                cardNumberField.leadingAnchor.constraint(equalTo: cardInfoBorderView.leadingAnchor, constant: 12),
                cardNumberField.trailingAnchor.constraint(equalTo: cardInfoBorderView.trailingAnchor, constant: -12),
                cardNumberField.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),

                brandIconView.trailingAnchor.constraint(equalTo: cardInfoBorderView.trailingAnchor, constant: -8),
                brandIconView.centerYAnchor.constraint(equalTo: cardNumberField.centerYAnchor),

                divider1.topAnchor.constraint(equalTo: cardNumberField.bottomAnchor),
                divider1.leadingAnchor.constraint(equalTo: cardInfoBorderView.leadingAnchor),
                divider1.trailingAnchor.constraint(equalTo: cardInfoBorderView.trailingAnchor),
                divider1.heightAnchor.constraint(equalToConstant: 0.5),

                expiryCVCStack.topAnchor.constraint(equalTo: divider1.bottomAnchor),
                expiryCVCStack.leadingAnchor.constraint(equalTo: cardInfoBorderView.leadingAnchor, constant: 12),
                expiryCVCStack.trailingAnchor.constraint(equalTo: cardInfoBorderView.trailingAnchor, constant: -12),
                expiryCVCStack.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
                expiryCVCStack.bottomAnchor.constraint(equalTo: cardInfoBorderView.bottomAnchor),

                cvcHintView.trailingAnchor.constraint(equalTo: cardInfoBorderView.trailingAnchor, constant: -8),
                cvcHintView.centerYAnchor.constraint(equalTo: cvcField.centerYAnchor),

                // Card holder section
                cardHolderLabel.topAnchor.constraint(equalTo: cardInfoBorderView.bottomAnchor, constant: 20),
                cardHolderLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
                cardHolderLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),

                cardHolderBorderView.topAnchor.constraint(equalTo: cardHolderLabel.bottomAnchor, constant: 8),
                cardHolderBorderView.leadingAnchor.constraint(equalTo: leadingAnchor),
                cardHolderBorderView.trailingAnchor.constraint(equalTo: trailingAnchor),

                cardholderField.topAnchor.constraint(equalTo: cardHolderBorderView.topAnchor),
                cardholderField.leadingAnchor.constraint(equalTo: cardHolderBorderView.leadingAnchor, constant: 12),
                cardholderField.trailingAnchor.constraint(equalTo: cardHolderBorderView.trailingAnchor, constant: -12),
                cardholderField.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
                cardholderField.bottomAnchor.constraint(equalTo: cardHolderBorderView.bottomAnchor),

                // Inline error label below the second group, pinned to the
                // outer view's bottom so the whole grouped form sizes
                // to-content.
                errorLabel.topAnchor.constraint(equalTo: cardHolderBorderView.bottomAnchor, constant: 4),
                errorLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
                errorLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
                errorLabel.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }

        /// Show or clear the inline validation message under the grouped
        /// container. Passing `nil` hides the label; MR3 wires this to the
        /// validator so failures no longer hop through a `UIAlertController`.
        package func showError(_ message: String?) {
            errorLabel.text = message
            errorLabel.isHidden = (message == nil)
        }

        /// Test-only inspection of the inline error label state. Returns
        /// `nil` when the label is hidden, the current message otherwise.
        /// `package` access keeps this invisible outside the SPM package.
        package var currentErrorMessageForTesting: String? {
            errorLabel.isHidden ? nil : errorLabel.text
        }

        /// Update the trailing brand icon inside the card-number row.
        /// Pass `nil` to revert to the generic card placeholder (the
        /// icon never hides — its slot stays reserved at all times).
        package func updateCardBrand(_ scheme: CardScheme?) {
            brandIconView.update(scheme: scheme)
        }

        /// Apply theme tokens to both border containers, dividers, field
        /// chrome, section labels, brand icon, CVC hint, and error label.
        /// Invoked from `MolliePaymentThemeApplier` so the VC stays out
        /// of the theming business.
        package func applyTheme(_ theme: MolliePaymentTheme) {
            let borderColor = theme.colors.fieldBorder.uiColor
            for border in [cardInfoBorderView, cardHolderBorderView] {
                border.layer.borderColor = borderColor.cgColor
                border.layer.cornerRadius = theme.cornerRadius
            }

            // Divider uses a fainter version of the border so the grouped
            // rows read as one container with internal separators rather
            // than two stacked cards.
            divider1.backgroundColor = borderColor.withAlphaComponent(0.4)

            let fieldBg = theme.colors.field.uiColor
            for item in [cardNumberField, expiryField, cvcField, cardholderField] {
                item.backgroundColor = fieldBg
                item.textColor = theme.colors.text.uiColor
                item.tintColor = theme.colors.primary.uiColor
            }

            let sectionFont = UIFont.systemFont(
                ofSize: CGFloat(theme.typography.sectionLabelFontSize),
                weight: .semibold
            )
            for label in [cardInfoLabel, cardHolderLabel] {
                label.font = sectionFont
                label.textColor = theme.colors.text.uiColor
            }

            errorLabel.textColor = theme.colors.error.uiColor

            brandIconView.applyTheme(theme)
            cvcHintView.applyTheme(theme)
        }
    }
#endif
