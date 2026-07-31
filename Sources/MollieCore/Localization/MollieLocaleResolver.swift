import Foundation

/// Resolves which localization to use for MollieCore-bundled strings, mirroring
/// the web SDK's fallback chain:
///   1. Explicit merchant override (`MollieCheckout(locale:)`)
///   2. System locale
///   3. Base-language fallback (region stripped, e.g. `nl_BE` → `nl`)
///   4. `en` default (guaranteed to exist)
///
/// Pure and UIKit-free — callers inject `system` (e.g. `Locale.current`) and
/// `availableIdentifiers` (e.g. `Bundle.module.localizations`) rather than the
/// resolver reading ambient state itself, so resolution stays deterministic
/// and unit-testable without any Bundle dependency.
package enum MollieLocaleResolver {
    /// Resolves the best-matching locale from `availableIdentifiers`.
    ///
    /// - Parameters:
    ///   - override: The merchant-supplied locale, if any.
    ///   - system: The device/system locale to fall back to when `override`
    ///     is `nil` or unsupported.
    ///   - availableIdentifiers: The locale identifiers the caller actually
    ///     ships strings for (e.g. `["en", "nl", "fr", "de"]`).
    /// - Returns: The matching `Locale` from `availableIdentifiers`, or `en`
    ///   if neither `override` nor `system` (nor their base languages) match.
    package static func resolve(
        override: Locale?,
        system: Locale,
        availableIdentifiers: [String]
    ) -> Locale {
        for candidate in [override, system].compactMap({ $0 }) {
            if let matched = match(candidate, in: availableIdentifiers) {
                return Locale(identifier: matched)
            }
        }
        return Locale(identifier: "en")
    }

    /// Matches `locale` against `available`, first by exact identifier, then
    /// by base language with region stripped (e.g. `nl_BE` → `nl`).
    private static func match(_ locale: Locale, in available: [String]) -> String? {
        if let exact = available.first(where: { $0.caseInsensitiveCompare(locale.identifier) == .orderedSame }) {
            return exact
        }
        guard let languageCode = locale.language.languageCode?.identifier else { return nil }
        return available.first { candidate in
            guard let candidateLanguageCode = Locale(identifier: candidate).language.languageCode?.identifier else {
                return false
            }
            return candidateLanguageCode.caseInsensitiveCompare(languageCode) == .orderedSame
        }
    }
}
