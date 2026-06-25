import XCTest
@testable import MollieCore

private final class TestFallbackMarker {}

private enum LocatorWithBundle: MollieBundleLocator {
    static let bundleName = "TestBundle_Present"
    static let spmResourcesBundle: Bundle? = Bundle(for: TestFallbackMarker.self)
    static let fallbackClass: AnyClass = TestFallbackMarker.self
}

private enum LocatorWithoutBundle: MollieBundleLocator {
    static let bundleName = "TestBundle_Missing"
    static let spmResourcesBundle: Bundle? = nil
    static let fallbackClass: AnyClass = TestFallbackMarker.self
}

final class MollieBundleLocatorTests: XCTestCase {
    func test_resourcesBundle_returnsSpmBundle_whenAvailable() {
        let expected = Bundle(for: TestFallbackMarker.self)
        XCTAssertEqual(LocatorWithBundle.resourcesBundle, expected)
    }

    func test_resourcesBundle_fallsBack_whenSpmBundleNil() {
        let expected = Bundle(for: TestFallbackMarker.self)
        XCTAssertEqual(LocatorWithoutBundle.resourcesBundle, expected)
    }

    func test_mollieCoreBundleLocator_hasCorrectBundleName() {
        XCTAssertEqual(MollieCoreBundleLocator.bundleName, "MollieCore_MollieCore")
    }
}
