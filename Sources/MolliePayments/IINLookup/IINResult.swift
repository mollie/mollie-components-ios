import Foundation

package struct IINResult: Codable, Equatable {
    package let scheme: CardScheme
    package let cardType: CardType?
    package let issuingCountry: String?

    package init(scheme: CardScheme, cardType: CardType?, issuingCountry: String?) {
        self.scheme = scheme
        self.cardType = cardType
        self.issuingCountry = issuingCountry
    }
}
