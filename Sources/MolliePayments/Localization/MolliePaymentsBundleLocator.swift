import Foundation
import MollieCore

/// Bundle locator for the MolliePayments target. `spmResourcesBundle` is `nil`
/// today because MolliePayments has no Resources/ directory declared in
/// Package.swift.
/// Once `MolliePaymentsUI` declares `.resources` on its target,
/// each library target with resources should replace `nil` with `Bundle.module`.
package enum MolliePaymentsBundleLocator: MollieBundleLocator {
    package static let bundleName = "MollieComponents_MolliePayments"
    package static let spmResourcesBundle: Bundle? = nil
    package static let fallbackClass: AnyClass = BundleLocatorMarker.self
}

private final class BundleLocatorMarker {}
