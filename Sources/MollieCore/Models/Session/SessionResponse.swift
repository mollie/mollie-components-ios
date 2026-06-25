public struct SessionResponse: Decodable, Equatable, Sendable {
    public let sessionToken: String
    public let status: ParsedEnum<SessionStatus>
    public let nextAction: NextAction
    public let paymentAmount: AmountDecimal
    public let remainingAmount: AmountDecimal?
    public let paymentMethodDetails: PaymentMethodDetails?
    public let redirectUrl: String?
}

public enum SessionStatus: String, Decodable, Equatable, Sendable {
    case open
    case completed
    case expired
}

public struct PaymentMethodDetails: Decodable, Equatable, Sendable {
    public let method: ParsedEnum<PaymentMethodType>
    public let params: [String: AnyCodable]?

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        method = try container.decode(ParsedEnum<PaymentMethodType>.self, forKey: .method)
        params = try? container.decodeIfPresent([String: AnyCodable].self, forKey: .params)
    }

    private enum CodingKeys: String, CodingKey {
        case method, params
    }
}
