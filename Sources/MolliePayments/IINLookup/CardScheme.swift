import Foundation

package enum CardScheme: Equatable, Hashable, Codable {
    case visa
    case mastercard
    case amex
    case maestro
    case discover
    case dinersClub
    case jcb
    case unionPay
    case cartesBancaires
    case other(String)

    package init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        switch raw.lowercased() {
        case "visa":
            self = .visa
        case "mastercard":
            self = .mastercard
        case "amex":
            self = .amex
        case "maestro":
            self = .maestro
        case "discover":
            self = .discover
        case "dinersclub":
            self = .dinersClub
        case "jcb":
            self = .jcb
        case "unionpay":
            self = .unionPay
        case "cartesbancaires":
            self = .cartesBancaires
        default:
            self = .other(raw)
        }
    }

    package func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .visa:
            try container.encode("visa")
        case .mastercard:
            try container.encode("mastercard")
        case .amex:
            try container.encode("amex")
        case .maestro:
            try container.encode("maestro")
        case .discover:
            try container.encode("discover")
        case .dinersClub:
            try container.encode("dinersClub")
        case .jcb:
            try container.encode("jcb")
        case .unionPay:
            try container.encode("unionPay")
        case .cartesBancaires:
            try container.encode("cartesBancaires")
        case let .other(raw):
            try container.encode(raw)
        }
    }

    /// Fixed priority used to deterministically collapse a multi-scheme
    /// detection result (`BINPrefixTable`/`IINResult`'s `Set<CardScheme>`)
    /// down to the single scheme a caller can display — e.g. the card
    /// form's brand icon, or the PAN field's grouping/cap, both of which
    /// can only ever act on one scheme at a time. Order is a deliberate but
    /// otherwise arbitrary business call (co-badge *display* precedence is
    /// out of scope here); it only matters for genuine BIN-range overlaps
    /// `BINPrefixTable` documents (e.g. Discover/UnionPay's shared alliance
    /// range). `nil` in -> `nil` out (placeholder). Schemes outside the
    /// priority list (only ever `.other`, since neither `BINPrefixTable`
    /// nor the wire contract's `IINResult` decoder ever produces one on
    /// their own) fall back to `schemes.first` rather than dropping the
    /// result on the floor.
    ///
    /// Single home for logic that used to be duplicated between
    /// `MollieCardFormViewController` (brand icon) and `CardNumberTextField`
    /// (PAN grouping) — `package` rather than `public` since both call
    /// sites live inside `MolliePaymentsUI`, which already imports this
    /// module, and `package` keeps `CardScheme` off the public surface
    /// (see `PublicSurfaceTests`, which pins the SDK's public API and has
    /// no reason to ever see this type).
    package static func primary(from schemes: Set<CardScheme>) -> CardScheme? {
        let priority: [CardScheme] = [
            .visa, .mastercard, .amex, .maestro, .discover, .dinersClub, .jcb, .unionPay, .cartesBancaires,
        ]
        for candidate in priority where schemes.contains(candidate) {
            return candidate
        }
        return schemes.first
    }
}
