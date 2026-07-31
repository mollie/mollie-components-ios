import Foundation
import MollieCore

/// Bundle locator for the MolliePaymentsUI target. MolliePaymentsUI's target
/// declares a `Resources/` directory in Package.swift (holding
/// `<locale>.lproj/Localizable.strings`), so SwiftPM generates
/// `Bundle.module` for it. The locale-threading work fills this bundle with
/// real UI copy; today it only carries a throwaway proof key.
package enum MolliePaymentsUIBundleLocator: MollieBundleLocator {
    package static let bundleName = "MollieComponents_MolliePaymentsUI"
    package static let spmResourcesBundle: Bundle? = Bundle.module
    package static let fallbackClass: AnyClass = BundleLocatorMarker.self
}

private final class BundleLocatorMarker {}
