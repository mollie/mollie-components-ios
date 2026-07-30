import Foundation

/// Local, offline, instant card-brand detection from a PAN's leading digits
/// (IIN/BIN — Issuer Identification Number / Bank Identification Number).
///
/// This is the **instant-UX authority**: `detect(prefix:)` is synchronous,
/// on-device, and needs no network round-trip, so the brand logo can update
/// on every keystroke. `IINLookupService`'s network lookup is the
/// **definitive** authority that reconciles (confirms or corrects) this
/// result once it returns.
///
/// Modeled as `Set<CardScheme>` rather than a single value because some BIN
/// ranges are genuinely shared between schemes (documented per-rule below),
/// and to stay forward-compatible with co-badged cards (E1) without a later
/// model reshape.
///
/// PCI safety: only ever examines the leading 6-8 digits of a PAN — never
/// the full number — and this type must never log its input.
package enum BINPrefixTable {
    /// - Parameter prefix: The leading digits of a PAN. Callers should pass
    ///   only the first 6-8 digits; passing more is harmless (only the
    ///   leading digits are ever read) but callers must never log this value.
    /// - Returns: Every scheme whose published BIN range matches `prefix`.
    ///   Empty when no known range matches — this never fabricates an
    ///   `.other` guess.
    package static func detect(prefix: String) -> Set<CardScheme> {
        // Reject anything containing a non-digit character outright, rather
        // than matching on whatever leading digits a rule happens to need —
        // a corrupted prefix should never partially match (mirrors Luhn's
        // all-or-nothing digit validation).
        guard prefix.allSatisfy({ $0.isASCII && $0.isNumber }) else { return [] }
        return Set(rules.filter { $0.matches(prefix) }.map(\.scheme))
    }

    private struct Rule {
        let scheme: CardScheme
        let digitCount: Int
        let range: ClosedRange<Int>

        func matches(_ prefix: String) -> Bool {
            guard prefix.count >= digitCount, let value = Int(prefix.prefix(digitCount)) else {
                return false
            }
            return range.contains(value)
        }
    }

    /// Ranges below are the well-known, publicly documented IIN/BIN
    /// allocations per scheme. Deliberately excluded: **Cartes Bancaires**,
    /// which co-badges onto Visa/Mastercard BINs and has no distinct
    /// globally-published range of its own — it can only be confirmed by the
    /// network IIN lookup, never guessed locally.
    private static let rules: [Rule] = [
        // Visa
        Rule(scheme: .visa, digitCount: 1, range: 4 ... 4),

        // Mastercard: 51-55, and the newer 2221-2720 range
        Rule(scheme: .mastercard, digitCount: 2, range: 51 ... 55),
        Rule(scheme: .mastercard, digitCount: 4, range: 2221 ... 2720),

        // American Express
        Rule(scheme: .amex, digitCount: 2, range: 34 ... 34),
        Rule(scheme: .amex, digitCount: 2, range: 37 ... 37),

        // Maestro
        Rule(scheme: .maestro, digitCount: 2, range: 50 ... 50),
        Rule(scheme: .maestro, digitCount: 2, range: 56 ... 58),
        Rule(scheme: .maestro, digitCount: 2, range: 67 ... 67),
        Rule(scheme: .maestro, digitCount: 4, range: 6304 ... 6304),
        Rule(scheme: .maestro, digitCount: 4, range: 6390 ... 6390),

        // Discover: 6011, 65, 644-649, and the 622126-622925 alliance range
        // shared with UnionPay (see UnionPay comment below).
        Rule(scheme: .discover, digitCount: 4, range: 6011 ... 6011),
        Rule(scheme: .discover, digitCount: 2, range: 65 ... 65),
        Rule(scheme: .discover, digitCount: 3, range: 644 ... 649),
        Rule(scheme: .discover, digitCount: 6, range: 622_126 ... 622_925),

        // Diners Club
        Rule(scheme: .dinersClub, digitCount: 3, range: 300 ... 305),
        Rule(scheme: .dinersClub, digitCount: 2, range: 36 ... 36),
        Rule(scheme: .dinersClub, digitCount: 2, range: 38 ... 39),

        // JCB
        Rule(scheme: .jcb, digitCount: 4, range: 3528 ... 3589),

        // UnionPay: 62 overall. Note this range genuinely overlaps Discover's
        // 622126-622925 alliance range above — both schemes are correctly
        // returned for prefixes in that intersection (real co-badge case,
        // not a bug).
        Rule(scheme: .unionPay, digitCount: 2, range: 62 ... 62),
    ]
}
