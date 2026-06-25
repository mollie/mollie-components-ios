import Foundation

/// Resolves the Bundle that holds a target's resources, working around the fact
/// that `Bundle.module` is only generated when SPM detects a Resources/ directory
/// in the target. Conformers supply their SPM-generated bundle (if any) and a
/// fallback class for `Bundle(for:)` lookup when running outside SPM contexts.
package protocol MollieBundleLocator {
    static var bundleName: String { get }
    static var spmResourcesBundle: Bundle? { get }
    static var fallbackClass: AnyClass { get }
}

package extension MollieBundleLocator {
    static var resourcesBundle: Bundle {
        spmResourcesBundle ?? Bundle(for: fallbackClass)
    }
}
