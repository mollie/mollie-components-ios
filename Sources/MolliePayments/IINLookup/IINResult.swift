import Foundation

package struct IINResult: Codable, Equatable {
    /// Multi-scheme-capable to support co-badged cards (e.g. Bancontact + Maestro).
    /// The wire contract only ever returns a single scheme today; that decodes into a one-element set.
    package let schemes: Set<CardScheme>
    package let cardType: CardType?
    package let issuingCountry: String?

    package init(schemes: Set<CardScheme>, cardType: CardType?, issuingCountry: String?) {
        self.schemes = schemes
        self.cardType = cardType
        self.issuingCountry = issuingCountry
    }

    private enum CodingKeys: String, CodingKey {
        case scheme
        case cardType
        case issuingCountry
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let scheme = try container.decode(CardScheme.self, forKey: .scheme)
        schemes = [scheme]
        cardType = try container.decodeIfPresent(CardType.self, forKey: .cardType)
        issuingCountry = try container.decodeIfPresent(String.self, forKey: .issuingCountry)
    }

    package func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        // Deterministic single-scheme collapse: `Set.first` is unordered, so a
        // multi-scheme co-badge value (e.g. Bancontact+Maestro) would encode an
        // arbitrary scheme and make round-trips non-reproducible. Use the same
        // priority-ordered `primary(from:)` every other collapse site uses,
        // falling back to `first` only for the (unreachable) empty set the guard
        // below still rejects.
        guard let scheme = CardScheme.primary(from: schemes) ?? schemes.first else {
            let context = EncodingError.Context(
                codingPath: encoder.codingPath,
                debugDescription: "IINResult requires at least one scheme to encode."
            )
            throw EncodingError.invalidValue(schemes, context)
        }
        try container.encode(scheme, forKey: .scheme)
        try container.encodeIfPresent(cardType, forKey: .cardType)
        try container.encodeIfPresent(issuingCountry, forKey: .issuingCountry)
    }
}
