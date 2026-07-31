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

    /// Resolves the specific `.lproj` sub-bundle for `locale`, bypassing
    /// `NSLocalizedString`'s system-preferred-language auto-selection.
    /// `NSLocalizedString(_:bundle:comment:)` picks a language table from
    /// `Bundle.preferredLocalizations`, which is derived from the device's
    /// preferred languages — it has no way to honour an explicit merchant
    /// locale override. Looking up the `<languageCode>.lproj` sub-bundle
    /// directly and handing THAT bundle to `NSLocalizedString` sidesteps
    /// that auto-selection entirely. Falls back to `en`, then to
    /// `resourcesBundle` itself if neither `.lproj` directory is present.
    static func localizedBundle(for locale: Locale) -> Bundle {
        let base = resourcesBundle
        let code = locale.language.languageCode?.identifier ?? "en"
        if let path = base.path(forResource: code, ofType: "lproj"), let bundle = Bundle(path: path) {
            return bundle
        }
        if let path = base.path(forResource: "en", ofType: "lproj"), let bundle = Bundle(path: path) {
            return bundle
        }
        return base
    }
}
