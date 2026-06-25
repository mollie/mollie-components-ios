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
}
