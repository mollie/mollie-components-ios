import MollieCore
import XCTest
@testable import MolliePaymentsUI

final class MolliePaymentsUIBundleLocatorTests: XCTestCase {
    func test_bundleName_isCorrect() {
        XCTAssertEqual(MolliePaymentsUIBundleLocator.bundleName, "MollieComponents_MolliePaymentsUI")
    }

    func test_resourcesBundle_usesSpmModuleBundle() {
        XCTAssertNotNil(MolliePaymentsUIBundleLocator.spmResourcesBundle)
        let bundle = MolliePaymentsUIBundleLocator.resourcesBundle
        XCTAssertFalse(bundle.bundleURL.lastPathComponent.isEmpty)
    }

    /// Proves the SPM resource bundle actually resolves `.strings` content,
    /// not just that a bundle URL exists. Phase 1 shipped a throwaway key
    /// here; Phase 3 replaced it with a real card-form localized string.
    func test_resourcesBundle_resolvesCardNumberPlaceholderKey() {
        let bundle = MolliePaymentsUIBundleLocator.resourcesBundle
        let value = NSLocalizedString(
            "card.number.placeholder",
            bundle: bundle,
            comment: ""
        )
        XCTAssertEqual(value, "1234 1234 1234 1234")
    }

    /// Proves `localizedBundle(for:)` deterministically resolves the `nl`
    /// sub-bundle for a Dutch locale, independent of whatever the test
    /// process's own system/preferred languages happen to be — this is the
    /// mechanism the locale-threading work uses to make a merchant-supplied
    /// locale override win over `NSLocalizedString`'s system-preferred-
    /// language auto-selection. A temporary `nl.lproj` with a single key
    /// ships alongside this test; Phase 5 replaces it with the full catalog.
    func test_localizedBundle_forNL_resolvesToNLProjSubBundle() {
        let bundle = MolliePaymentsUIBundleLocator.localizedBundle(for: Locale(identifier: "nl"))
        XCTAssertEqual(bundle.bundleURL.lastPathComponent, "nl.lproj")
        let value = NSLocalizedString("card.holder.placeholder", bundle: bundle, comment: "")
        XCTAssertEqual(value, "Naam op de kaart")
    }

    /// A locale with no shipped `.lproj` (the locale-threading work ships
    /// en/nl/fr/de only) must fall back to `en`, not silently resolve to
    /// whichever bundle `NSLocalizedString` would have auto-picked.
    func test_localizedBundle_forUnsupportedLocale_fallsBackToEnglish() {
        let bundle = MolliePaymentsUIBundleLocator.localizedBundle(for: Locale(identifier: "es"))
        XCTAssertEqual(bundle.bundleURL.lastPathComponent, "en.lproj")
    }
}
