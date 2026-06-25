import Foundation

/// Bundle locator for the MollieCore target. `spmResourcesBundle` is `nil` today
/// because MollieCore has no Resources/ directory declared in Package.swift.
/// - Phase 3: when `MolliePaymentsUI` declares `.resources` on its target,
/// each library target with resources should replace `nil` with `Bundle.module`.
package enum MollieCoreBundleLocator: MollieBundleLocator {
    package static let bundleName = "MollieCore_MollieCore"
    package static let spmResourcesBundle: Bundle? = nil
    package static let fallbackClass: AnyClass = BundleLocatorMarker.self
}

private final class BundleLocatorMarker {}
