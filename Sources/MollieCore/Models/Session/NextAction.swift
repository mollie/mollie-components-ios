public struct NextAction: Decodable, Equatable, Sendable {
    public let actionType: ParsedEnum<ActionType>
    public let params: [String: AnyCodable]?
    public let eventId: Int?

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        actionType = try container.decode(ParsedEnum<ActionType>.self, forKey: .actionType)
        eventId = try container.decodeIfPresent(Int.self, forKey: .eventId)
        // PHP serialises empty dicts as `[]`; treat that as nil params but
        // rethrow any other decoding error so genuine bugs aren't swallowed.
        do {
            params = try container.decodeIfPresent([String: AnyCodable].self, forKey: .params)
        } catch DecodingError.typeMismatch {
            params = nil
        }
    }

    private enum CodingKeys: String, CodingKey {
        case actionType, params, eventId
    }
}

public enum ActionType: String, Decodable, Equatable, Sendable {
    case none
    case redirect
    case iframe
    case error
    case bancontactPaymentUrl
    case awaiting = "await"
    case threeDsChallenge
    case reset
    case closePopup
    case readyToProcess
    case providerSessionCreationRequested
    case providerSessionCreated
    case providerSessionCreationFailed
}
