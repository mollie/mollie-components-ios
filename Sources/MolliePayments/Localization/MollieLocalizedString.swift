import Foundation

/// Resolves a localized string from the MolliePayments resource bundle.
/// `bundle`, when supplied, is used verbatim instead of the default
/// system-preferred-language bundle — see the MolliePaymentsUI counterpart
/// for the full rationale. Defaults to `nil` (system behaviour).
package func MollieLocalizedString( // swiftlint:disable:this identifier_name
    _ key: String,
    bundle: Bundle? = nil,
    comment: String
) -> String {
    NSLocalizedString(key, bundle: bundle ?? MolliePaymentsBundleLocator.resourcesBundle, comment: comment)
}
