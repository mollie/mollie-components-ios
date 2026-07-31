import MollieCore
import XCTest
@testable import MolliePayments

final class MolliePaymentsBundleLocatorTests: XCTestCase {
    func test_bundleName_isCorrect() {
        XCTAssertEqual(MolliePaymentsBundleLocator.bundleName, "MollieComponents_MolliePayments")
    }

    func test_resourcesBundle_usesSpmModuleBundle() {
        XCTAssertNotNil(MolliePaymentsBundleLocator.spmResourcesBundle)
        let bundle = MolliePaymentsBundleLocator.resourcesBundle
        XCTAssertFalse(bundle.bundleURL.lastPathComponent.isEmpty)
    }

    /// Proves the SPM resource bundle actually resolves `.strings` content,
    /// not just that a bundle URL exists. Phase 1 shipped a single throwaway
    /// key here; the locale-threading work replaced it with the real
    /// 3-D Secure copy.
    func test_resourcesBundle_resolvesThreeDSTitleKey() {
        let bundle = MolliePaymentsBundleLocator.resourcesBundle
        let value = NSLocalizedString(
            "threeds.title",
            bundle: bundle,
            comment: ""
        )
        XCTAssertEqual(value, "3-D Secure")
    }
}
