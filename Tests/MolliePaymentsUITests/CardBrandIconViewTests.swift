#if canImport(UIKit)
    import MolliePayments
    import UIKit
    import XCTest
    @testable import MolliePaymentsUI

    /// Icon switch coverage. `CardBrandIconView.image(for:)`
    /// must resolve every shipped brand asset (visa/mastercard/amex/
    /// cartesBancaires/maestro) and fall back consistently for schemes
    /// without dedicated artwork, so a merchant never sees a blank or
    /// mismatched brand mark once IIN lookup resolves a scheme.
    final class CardBrandIconViewTests: XCTestCase {
        /// Schemes with dedicated `Brands.xcassets` artwork, mapped to the
        /// asset name each must resolve to.
        ///
        /// `card-maestro` is a documented exception: no real Maestro mark
        /// exists yet (the Web SDK has none either), so that asset
        /// intentionally reuses the generic placeholder artwork as a
        /// slot-filler. It's still asserted here so a future real-artwork
        /// swap is covered without a test change.
        private static let shippedSchemes: [(scheme: CardScheme, assetName: String)] = [
            (.visa, "card-visa"),
            (.mastercard, "card-mastercard"),
            (.amex, "card-amex"),
            (.cartesBancaires, "card-cartesbancaires"),
            (.maestro, "card-maestro"),
        ]

        /// Schemes with no dedicated asset in `Brands.xcassets`. These
        /// must not return nil (the icon view never wants to render
        /// nothing) and must all resolve to the same fallback image.
        private static let unmappedSchemes: [CardScheme] = [
            .discover,
            .dinersClub,
            .jcb,
            .unionPay,
            .other("some-future-network"),
        ]

        func test_image_resolvesNonNilForEveryShippedScheme() {
            for (scheme, _) in Self.shippedSchemes {
                XCTAssertNotNil(
                    CardBrandIconView.image(for: scheme),
                    "\(scheme) must resolve to a non-nil image"
                )
            }
        }

        func test_image_resolvesTheDedicatedAssetForEachShippedScheme() {
            // Each shipped scheme must map to its own named asset — not
            // silently collapse onto a neighbour's (e.g. a copy-paste bug
            // mapping .maestro to the mastercard asset) or onto the SF
            // Symbol fallback path.
            for (scheme, assetName) in Self.shippedSchemes {
                let expected = UIImage(named: assetName, in: Bundle.module, compatibleWith: nil)
                XCTAssertNotNil(expected, "\(assetName) must exist in Brands.xcassets")
                XCTAssertEqual(
                    CardBrandIconView.image(for: scheme)?.pngData(),
                    expected?.pngData(),
                    "\(scheme) must resolve to its dedicated \(assetName) asset"
                )
            }
        }

        func test_image_shippedSchemesWithDistinctArtworkDoNotCollide() {
            // .maestro is excluded — it intentionally reuses the generic
            // placeholder SVG (see the doc comment on `shippedSchemes`)
            // until real artwork is sourced, so it collides with the
            // placeholder by design, not by bug.
            let distinctArtworkSchemes = Self.shippedSchemes.filter { $0.scheme != .maestro }
            let placeholder = CardBrandIconView.image(for: .discover)?.pngData()
            var seen: [Data] = []
            for (scheme, _) in distinctArtworkSchemes {
                guard let data = CardBrandIconView.image(for: scheme)?.pngData() else {
                    XCTFail("\(scheme) produced no renderable image")
                    continue
                }
                XCTAssertFalse(
                    seen.contains(data),
                    "\(scheme) resolved to an image already used by another shipped scheme"
                )
                XCTAssertNotEqual(
                    data,
                    placeholder,
                    "\(scheme) must not fall back to the generic placeholder"
                )
                seen.append(data)
            }
        }

        func test_image_unmappedSchemesFallBackToSharedPlaceholder() {
            // Schemes without dedicated artwork must never return nil,
            // and must all resolve to the same fallback image rather than
            // each drifting to a different ad-hoc result.
            guard let placeholder = CardBrandIconView.image(for: .discover)?.pngData() else {
                return XCTFail("Placeholder fallback must render a non-nil image")
            }
            for scheme in Self.unmappedSchemes {
                XCTAssertEqual(
                    CardBrandIconView.image(for: scheme)?.pngData(),
                    placeholder,
                    "\(scheme) must fall back to the same shared placeholder image"
                )
            }
        }
    }
#endif
