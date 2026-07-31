import Foundation

/// Resolves a localized string from the MolliePaymentsUI resource bundle.
/// `bundle`, when supplied, is used verbatim instead of the default
/// system-preferred-language bundle — callers pass the locale-specific
/// `.lproj` sub-bundle from `MollieBundleLocator.localizedBundle(for:)` so a
/// merchant-supplied locale override wins over the device's own preferred
/// languages. Defaults to `nil` (system behaviour) so existing call sites
/// that don't yet thread a resolved locale keep working unchanged.
package func MollieLocalizedString( // swiftlint:disable:this identifier_name
    _ key: String,
    bundle: Bundle? = nil,
    comment: String
) -> String {
    NSLocalizedString(key, bundle: bundle ?? MolliePaymentsUIBundleLocator.resourcesBundle, comment: comment)
}
