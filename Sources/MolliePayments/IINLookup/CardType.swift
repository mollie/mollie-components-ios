import Foundation

package enum CardType: String, Equatable, Codable {
    case credit
    case debit
    case prepaid
    case unknown

    package init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        self = CardType(rawValue: raw) ?? .unknown
    }
}
