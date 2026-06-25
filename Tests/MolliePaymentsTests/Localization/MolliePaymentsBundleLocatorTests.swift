import MollieCore
import XCTest
@testable import MolliePayments

final class MolliePaymentsBundleLocatorTests: XCTestCase {
    func test_bundleName_isCorrect() {
        XCTAssertEqual(MolliePaymentsBundleLocator.bundleName, "MollieComponents_MolliePayments")
    }

    func test_resourcesBundle_fallsBack_whenSpmBundleNil() {
        XCTAssertNil(MolliePaymentsBundleLocator.spmResourcesBundle)
        let bundle = MolliePaymentsBundleLocator.resourcesBundle
        XCTAssertFalse(bundle.bundleURL.lastPathComponent.isEmpty)
    }
}
