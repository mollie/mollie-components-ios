#if canImport(UIKit)
    import MolliePayments
    import UIKit

    /// Trailing accessory inside the card-number row. Shows a generic
    /// card placeholder by default (matching the Web SDK's resting state)
    /// and cross-fades to the resolved brand mark when `update(scheme:)`
    /// lands a known card scheme. Passing `nil` to `update(scheme:)`
    /// returns to the placeholder rather than hiding the view.
    ///
    /// MR3 wires only the layout + image-resolution. The IIN call that
    /// drives `update(scheme:)` lands when `MollieCardFormViewController`
    /// gains its lookup integration in Phase 5. The placeholder is
    /// visible immediately so the row never looks empty and layout never
    /// jumps when a real brand finally resolves.
    package final class CardBrandIconView: UIView {
        private let imageView: UIImageView = {
            let view = UIImageView()
            view.contentMode = .scaleAspectFit
            view.translatesAutoresizingMaskIntoConstraints = false
            return view
        }()

        /// Current placeholder tint. Tracked so `applyTheme(_:)` can
        /// recolour the placeholder without re-rendering the image
        /// when a brand has already been resolved.
        private var placeholderTint: UIColor = .label.withAlphaComponent(0.35)

        package init() {
            super.init(frame: .zero)
            translatesAutoresizingMaskIntoConstraints = false
            addSubview(imageView)
            NSLayoutConstraint.activate([
                widthAnchor.constraint(equalToConstant: 24),
                heightAnchor.constraint(equalToConstant: 16),
                imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
                imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
                imageView.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor),
                imageView.heightAnchor.constraint(lessThanOrEqualTo: heightAnchor),
            ])
            imageView.image = Self.placeholderImage()
            imageView.tintColor = placeholderTint
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("CardBrandIconView does not support NSCoder")
        }

        /// Last scheme handed to `update(scheme:)`. The animation completion
        /// re-reads this before swapping the image, so a rapid sequence
        /// (`visa -> mastercard -> visa`) cannot leave a stale image on
        /// screen because an earlier completion fires after a later call.
        private var pendingScheme: CardScheme?

        /// Swap in the brand mark for `scheme`, fading the old image out
        /// first so a typed-then-corrected PAN doesn't pop the icon.
        /// Pass `nil` to return to the generic card placeholder (the
        /// view never hides — it always occupies its 24x16 slot).
        package func update(scheme: CardScheme?) {
            pendingScheme = scheme
            let image = scheme.flatMap { Self.image(for: $0) } ?? Self.placeholderImage()
            let isPlaceholder = (scheme == nil)
            // `beginFromCurrentState` so a mid-flight fade doesn't snap
            // back to its start point when a new call lands — the user
            // sees one continuous animation, not a stutter.
            UIView.animate(
                withDuration: 0.15,
                delay: 0,
                options: [.beginFromCurrentState],
                animations: { self.imageView.alpha = 0 },
                completion: { [weak self] _ in
                    guard let self else { return }
                    // Only commit if no newer call has replaced our scheme;
                    // otherwise the newer call's animation owns the final
                    // image and we bail to avoid clobbering it.
                    guard pendingScheme == scheme else { return }
                    imageView.image = image
                    imageView.tintColor = isPlaceholder ? placeholderTint : nil
                    UIView.animate(
                        withDuration: 0.15,
                        delay: 0,
                        options: [.beginFromCurrentState],
                        animations: { self.imageView.alpha = 1 },
                        completion: nil
                    )
                }
            )
        }

        /// Re-tint the placeholder so a merchant-supplied theme can swap
        /// the resting-state foreground without subclassing. Resolved
        /// brand artwork is rendered without a tint (its own colours win).
        package func applyTheme(_ theme: MolliePaymentTheme) {
            placeholderTint = theme.colors.text.uiColor.withAlphaComponent(0.35)
            if pendingScheme == nil {
                imageView.tintColor = placeholderTint
            }
        }

        /// Generic card placeholder used at rest. SF Symbol so no asset
        /// shipping is required; tint is driven by `applyTheme(_:)`.
        private static func placeholderImage() -> UIImage? {
            UIImage(systemName: "creditcard")
        }

        private static func image(for scheme: CardScheme) -> UIImage? {
            // Named asset first so Phase 5 can ship real brand artwork in
            // the bundle without touching this file; SF Symbol fallback
            // keeps the icon non-empty in dev / tests until then.
            //
            // `Bundle.module` is generated by SwiftPM once the target
            // declares any `resources:` entry — see Package.swift, which
            // wires `Brands.xcassets` (currently an empty shell).
            let bundle = Bundle.module
            switch scheme {
            case .visa:
                return UIImage(named: "card-visa", in: bundle, compatibleWith: nil)
                    ?? UIImage(systemName: "creditcard")
            case .mastercard:
                return UIImage(named: "card-mastercard", in: bundle, compatibleWith: nil)
                    ?? UIImage(systemName: "creditcard.fill")
            default:
                return nil
            }
        }
    }
#endif
