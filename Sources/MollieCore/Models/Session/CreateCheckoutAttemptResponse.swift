import Foundation

public struct CreateCheckoutAttemptResponse: Decodable, Sendable {
    public let checkoutAttemptToken: String

    public init(checkoutAttemptToken: String) {
        self.checkoutAttemptToken = checkoutAttemptToken
    }

    private enum CodingKeys: String, CodingKey {
        case checkoutAttemptToken
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let token = try container.decode(String.self, forKey: .checkoutAttemptToken)
        // Empty token is a backend contract violation — the SDK cannot poll
        // `/checkout-attempts/` without a non-empty key. Fail fast at decode
        // so the caller sees a DecodingError instead of a silent map-miss
        // that would manifest as a polling timeout minutes later.
        guard !token.isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .checkoutAttemptToken,
                in: container,
                debugDescription: "checkoutAttemptToken must not be empty"
            )
        }
        checkoutAttemptToken = token
    }
}
