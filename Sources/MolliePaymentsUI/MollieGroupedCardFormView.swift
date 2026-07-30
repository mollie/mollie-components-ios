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
        /// Row pairing the expiry and CVC fields. Built eagerly (rather
        /// than as a `setupLayout()` local) so its height constraint can
        /// be constructed alongside the other field constraints below.
        private let expiryCVCStack: UIStackView

        /// Minimum-height constraints for the three field rows. Built in
        /// `init` — before `super.init()` — so they can be stored as
        /// non-optionals; `applyTheme(_:)` retargets `.constant` from
        /// `theme.fieldMinHeight` without ever going through an implicitly
        /// unwrapped optional.
        private let cardNumberHeightConstraint: NSLayoutConstraint
        private let expiryCVCHeightConstraint: NSLayoutConstraint
        private let cardholderHeightConstraint: NSLayoutConstraint

        /// Last theme applied via `applyTheme(_:)`. Cached so
        /// `applyFocusState(to:focused:)` can restore the exact themed
        /// default border (colour + width) on blur without re-deriving it,
        /// and so a re-theme (e.g. light/dark trait change) can re-assert
        /// the focus ring on whichever field is still first responder.
        private var currentTheme: MollieAppearance = .default

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

        /// Per-field caption labels, shown below their field when
        /// `showFieldErrors(_:)` reports a message for that field. Hidden by
        /// default. Kept alongside `errorLabel` rather than replacing it, so
        /// callers still on the single-message API keep working.
        private let cardNumberErrorLabel = MollieGroupedCardFormView.makeFieldErrorLabel()
        private let expiryErrorLabel = MollieGroupedCardFormView.makeFieldErrorLabel()
        private let cvcErrorLabel = MollieGroupedCardFormView.makeFieldErrorLabel()
        private let cardholderErrorLabel = MollieGroupedCardFormView.makeFieldErrorLabel()

        private static func makeFieldErrorLabel() -> UILabel {
            let label = UILabel()
            label.font = .preferredFont(forTextStyle: .caption1)
            label.adjustsFontForContentSizeCategory = true
            label.numberOfLines = 0
            label.isHidden = true
            label.translatesAutoresizingMaskIntoConstraints = false
            return label
        }

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
            let expiryCVCStack = UIStackView(arrangedSubviews: [expiryField, cvcField])
            self.expiryCVCStack = expiryCVCStack
            cardNumberHeightConstraint = cardNumberField.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)
            expiryCVCHeightConstraint = expiryCVCStack.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)
            cardholderHeightConstraint = cardholderField.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)
            super.init(frame: .zero)
            setupLayout()
            configureFocusHandling()
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("MollieGroupedCardFormView does not support NSCoder")
        }

        private func setupLayout() {
            translatesAutoresizingMaskIntoConstraints = false

            for border in [cardInfoBorderView, cardHolderBorderView] {
                border.translatesAutoresizingMaskIntoConstraints = false
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

            let expiryCVCErrorStack = UIStackView(arrangedSubviews: [expiryErrorLabel, cvcErrorLabel])
            expiryCVCErrorStack.axis = .horizontal
            expiryCVCErrorStack.distribution = .fillEqually
            expiryCVCErrorStack.spacing = 8
            expiryCVCErrorStack.translatesAutoresizingMaskIntoConstraints = false

            addSubview(cardInfoLabel)
            addSubview(cardNumberErrorLabel)
            addSubview(expiryCVCErrorStack)
            addSubview(cardHolderLabel)
            addSubview(cardholderErrorLabel)
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
                cardNumberHeightConstraint,

                brandIconView.trailingAnchor.constraint(equalTo: cardInfoBorderView.trailingAnchor, constant: -8),
                brandIconView.centerYAnchor.constraint(equalTo: cardNumberField.centerYAnchor),

                divider1.topAnchor.constraint(equalTo: cardNumberField.bottomAnchor),
                divider1.leadingAnchor.constraint(equalTo: cardInfoBorderView.leadingAnchor),
                divider1.trailingAnchor.constraint(equalTo: cardInfoBorderView.trailingAnchor),
                divider1.heightAnchor.constraint(equalToConstant: 0.5),

                expiryCVCStack.topAnchor.constraint(equalTo: divider1.bottomAnchor),
                expiryCVCStack.leadingAnchor.constraint(equalTo: cardInfoBorderView.leadingAnchor, constant: 12),
                expiryCVCStack.trailingAnchor.constraint(equalTo: cardInfoBorderView.trailingAnchor, constant: -12),
                expiryCVCHeightConstraint,
                expiryCVCStack.bottomAnchor.constraint(equalTo: cardInfoBorderView.bottomAnchor),

                cvcHintView.trailingAnchor.constraint(equalTo: cardInfoBorderView.trailingAnchor, constant: -8),
                cvcHintView.centerYAnchor.constraint(equalTo: cvcField.centerYAnchor),

                // Per-field caption labels for the card-information group,
                // stacked below the bordered box: card number first, then
                // expiry/CVC side by side (mirroring their field row).
                cardNumberErrorLabel.topAnchor.constraint(equalTo: cardInfoBorderView.bottomAnchor, constant: 4),
                cardNumberErrorLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
                cardNumberErrorLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),

                expiryCVCErrorStack.topAnchor.constraint(equalTo: cardNumberErrorLabel.bottomAnchor, constant: 2),
                expiryCVCErrorStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
                expiryCVCErrorStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),

                // Card holder section
                cardHolderLabel.topAnchor.constraint(equalTo: expiryCVCErrorStack.bottomAnchor, constant: 16),
                cardHolderLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
                cardHolderLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),

                cardHolderBorderView.topAnchor.constraint(equalTo: cardHolderLabel.bottomAnchor, constant: 8),
                cardHolderBorderView.leadingAnchor.constraint(equalTo: leadingAnchor),
                cardHolderBorderView.trailingAnchor.constraint(equalTo: trailingAnchor),

                cardholderField.topAnchor.constraint(equalTo: cardHolderBorderView.topAnchor),
                cardholderField.leadingAnchor.constraint(equalTo: cardHolderBorderView.leadingAnchor, constant: 12),
                cardholderField.trailingAnchor.constraint(equalTo: cardHolderBorderView.trailingAnchor, constant: -12),
                cardholderHeightConstraint,
                cardholderField.bottomAnchor.constraint(equalTo: cardHolderBorderView.bottomAnchor),

                // Per-field caption label for the cardholder group.
                cardholderErrorLabel.topAnchor.constraint(equalTo: cardHolderBorderView.bottomAnchor, constant: 4),
                cardholderErrorLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
                cardholderErrorLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),

                // Inline error label below the cardholder caption, pinned to
                // the outer view's bottom so the whole grouped form sizes
                // to-content.
                errorLabel.topAnchor.constraint(equalTo: cardholderErrorLabel.bottomAnchor, constant: 4),
                errorLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
                errorLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
                errorLabel.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }

        /// Wires focus/blur border feedback once per field, at init.
        /// Deliberately separate from `applyTheme(_:)` — which can run many
        /// times over a view's lifetime (trait changes) — so the targets
        /// are never registered more than once per field.
        private func configureFocusHandling() {
            for field in [cardNumberField, expiryField, cvcField, cardholderField] {
                field.addTarget(self, action: #selector(fieldDidBeginEditing(_:)), for: .editingDidBegin)
                field.addTarget(self, action: #selector(fieldDidEndEditing(_:)), for: .editingDidEnd)
            }
        }

        @objc
        private func fieldDidBeginEditing(_ sender: UITextField) {
            applyFocusState(to: sender, focused: true)
        }

        @objc
        private func fieldDidEndEditing(_ sender: UITextField) {
            applyFocusState(to: sender, focused: false)
        }

        /// The bordered container enclosing `field`. Card number, expiry,
        /// and CVC all share `cardInfoBorderView` (they're one visually
        /// collapsed group by design); the cardholder field has its own
        /// container.
        private func borderContainer(for field: UITextField) -> UIView {
            field === cardholderField ? cardHolderBorderView : cardInfoBorderView
        }

        /// Toggles `field`'s enclosing container border between the themed
        /// default and the iOS-native system tint. Resolved decision:
        /// the focus indicator uses `tintColor` — the view's inherited
        /// system tint, `.systemBlue` absent an explicit override — rather
        /// than porting the Web SDK's hard-coded `#458fff` focus outline.
        /// Also bumps the stroke width slightly on focus for a native-style
        /// emphasis ring; `layer.borderWidth` draws inward, so this never
        /// shifts layout. `package` so tests can drive it directly — the
        /// `editingDidBegin`/`editingDidEnd` control events this backs
        /// don't fire reliably via `sendActions` in the headless-sim test
        /// harness.
        package func applyFocusState(to field: UITextField, focused: Bool) {
            let container = borderContainer(for: field)
            if focused {
                container.layer.borderColor = tintColor.cgColor
                container.layer.borderWidth = currentTheme.fieldBorderWidth + 1
            } else {
                container.layer.borderColor = currentTheme.colors.fieldBorder.uiColor.cgColor
                container.layer.borderWidth = currentTheme.fieldBorderWidth
            }
        }

        /// Test-only inspection of a field's enclosing container border
        /// colour, for asserting the focus/blur swap. `package` access
        /// keeps this invisible outside the SPM package.
        package func borderColorForTesting(_ field: UITextField) -> CGColor? {
            borderContainer(for: field).layer.borderColor
        }

        /// Test-only inspection of a field's enclosing container border
        /// width, for asserting the focus-width bump. `package` access
        /// keeps this invisible outside the SPM package.
        package func borderWidthForTesting(_ field: UITextField) -> CGFloat {
            borderContainer(for: field).layer.borderWidth
        }

        /// Show or clear the inline validation message under the grouped
        /// container. Passing `nil` hides the label; wires this to the
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

        /// Show or clear per-field validation captions below each of the
        /// four fields. A field missing from `errors` (or mapped to an
        /// empty string) has its caption hidden. Does not touch the
        /// shared `errorLabel` — `showError(_:)` keeps working
        /// independently for callers still on the single-message API.
        package func showFieldErrors(_ errors: [CardField: String]) {
            for field in Self.allFields {
                let label = fieldErrorLabel(for: field)
                let message = errors[field]
                let isEmpty = message?.isEmpty ?? true
                label.text = isEmpty ? nil : message
                label.isHidden = isEmpty
            }
        }

        private static let allFields: [CardField] = [.cardholder, .pan, .expiry, .cvc]

        private func fieldErrorLabel(for field: CardField) -> UILabel {
            switch field {
            case .cardholder: cardholderErrorLabel
            case .pan: cardNumberErrorLabel
            case .expiry: expiryErrorLabel
            case .cvc: cvcErrorLabel
            }
        }

        /// Test-only inspection of a per-field caption's state. Returns
        /// `nil` when the field's label is hidden, the current message
        /// otherwise. `package` access keeps this invisible outside the
        /// SPM package.
        package func fieldErrorTextForTesting(_ field: CardField) -> String? {
            let label = fieldErrorLabel(for: field)
            return label.isHidden ? nil : label.text
        }

        /// Test-only inspection of the grouped border containers' stroke
        /// width. Both containers always share one theme-driven width, so
        /// either suffices. `package` access keeps this invisible outside
        /// the SPM package.
        package var fieldBorderWidthForTesting: CGFloat {
            cardInfoBorderView.layer.borderWidth
        }

        /// Test-only inspection of the field-row minimum-height
        /// constraints. All three rows always share one theme-driven
        /// value, so either suffices. `package` access keeps this
        /// invisible outside the SPM package.
        package var fieldMinHeightForTesting: CGFloat {
            cardNumberHeightConstraint.constant
        }

        /// Update the trailing brand icon inside the card-number row.
        /// Pass `nil` to revert to the generic card placeholder (the
        /// icon never hides — its slot stays reserved at all times).
        package func updateCardBrand(_ scheme: CardScheme?) {
            brandIconView.update(scheme: scheme)
        }

        /// Test-only inspection of the trailing brand icon's currently
        /// requested scheme. `package` access keeps this invisible outside
        /// the SPM package.
        package var currentBrandSchemeForTesting: CardScheme? {
            brandIconView.currentSchemeForTesting
        }

        /// Apply theme tokens to both border containers, dividers, field
        /// chrome, section labels, brand icon, CVC hint, and the shared +
        /// per-field error labels. Invoked from `MollieAppearanceApplier`
        /// so the VC stays out of the theming business.
        package func applyTheme(_ theme: MollieAppearance) {
            currentTheme = theme
            let borderColor = theme.colors.fieldBorder.uiColor
            for border in [cardInfoBorderView, cardHolderBorderView] {
                border.layer.borderColor = borderColor.cgColor
                border.layer.borderWidth = theme.fieldBorderWidth
                border.layer.cornerRadius = theme.cornerRadius
            }

            for constraint in [cardNumberHeightConstraint, expiryCVCHeightConstraint, cardholderHeightConstraint] {
                constraint.constant = theme.fieldMinHeight
            }

            // Divider uses a fainter version of the border so the grouped
            // rows read as one container with internal separators rather
            // than two stacked cards.
            divider1.backgroundColor = borderColor.withAlphaComponent(0.4)

            let fieldBg = theme.colors.field.uiColor
            let placeholderColor = theme.colors.placeholder.uiColor
            for item in [cardNumberField, expiryField, cvcField, cardholderField] {
                item.backgroundColor = fieldBg
                item.textColor = theme.colors.text.uiColor
                item.tintColor = theme.colors.primary.uiColor
                // Re-derive the attributed placeholder on every theme
                // application rather than storing it once: this is the
                // only path that colours placeholder text at all — UIKit's
                // default is an unthemed system grey.
                if let placeholderText = item.placeholder {
                    item.attributedPlaceholder = NSAttributedString(
                        string: placeholderText,
                        attributes: [.foregroundColor: placeholderColor]
                    )
                }
            }

            let sectionFont = UIFont.systemFont(
                ofSize: CGFloat(theme.typography.sectionLabelFontSize),
                weight: .semibold
            )
            for label in [cardInfoLabel, cardHolderLabel] {
                label.font = sectionFont
                label.textColor = theme.colors.text.uiColor
            }

            let errorColor = theme.colors.error.uiColor
            for label in [errorLabel, cardNumberErrorLabel, expiryErrorLabel, cvcErrorLabel, cardholderErrorLabel] {
                label.textColor = errorColor
            }

            brandIconView.applyTheme(theme)
            cvcHintView.applyTheme(theme)

            // The border reset above just overwrote any active focus ring
            // (e.g. a light/dark trait change firing mid-edit); if a field
            // is still first responder, re-assert its tinted border on top
            // of the freshly themed default.
            let fields = [cardNumberField, expiryField, cvcField, cardholderField]
            if let focusedField = fields.first(where: { $0.isFirstResponder }) {
                applyFocusState(to: focusedField, focused: true)
            }
        }
    }
#endif
