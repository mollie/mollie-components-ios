import Foundation

/// Bundle locator for the MollieCore target. MollieCore's target declares a
/// `resources:` entry in Package.swift (currently `PrivacyInfo.xcprivacy`),
/// so SwiftPM generates `Bundle.module` for it. MollieCore does not ship its
/// own `Localizable.strings` — see ADR-0007 — so this locator exists purely
/// as plumbing for conformers/tests exercising `MollieBundleLocator`.
package enum MollieCoreBundleLocator: MollieBundleLocator {
    package static let bundleName = "MollieCore_MollieCore"
    package static let spmResourcesBundle: Bundle? = Bundle.module
    package static let fallbackClass: AnyClass = BundleLocatorMarker.self
}

private final class BundleLocatorMarker {}
