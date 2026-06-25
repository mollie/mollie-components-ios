import Foundation

package struct CardToken: Equatable, Decodable {
    package let value: String

    package init(value: String) {
        self.value = value
    }

    private enum CodingKeys: String, CodingKey {
        case value = "cardToken"
    }
}
