#if canImport(UIKit)
    import UIKit
    import XCTest
    @testable import MolliePaymentsUI

    /// Proves the locale-threading work actually makes the
    /// merchant's explicit `locale:` override win over whatever the test
    /// process's own system/preferred languages happen to be —
    /// `NSLocalizedString`'s default bundle-selection has no way to honour
    /// an override, which is exactly the gap this locale-aware bundle
    /// lookup closes. A temporary `nl.lproj` with a single key
    /// (`card.holder.placeholder`) ships alongside this test; Phase 5
    /// replaces it with the full Dutch catalog.
    @MainActor
    final class CardFormViewControllerLocaleTests: XCTestCase {
        func test_explicitDutchLocale_winsOverSystemLocale_forFieldPlaceholder() {
            let form = MollieCardFormViewController(locale: Locale(identifier: "nl"))
            form.loadViewIfNeeded()
            XCTAssertEqual(form.cardholderField.placeholder, "Naam op de kaart")
        }

        func test_englishLocale_resolvesEnglishPlaceholder() {
            // Explicit `en` override: keeps this deterministic regardless of
            // the test runner's own system/preferred locale, now that nl/fr/de
            // catalogs also ship and `.current` could otherwise resolve one of
            // those on a non-English runner.
            let form = MollieCardFormViewController(locale: Locale(identifier: "en"))
            form.loadViewIfNeeded()
            XCTAssertEqual(form.cardholderField.placeholder, "Full name on card")
        }
    }
#endif
