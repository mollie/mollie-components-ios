/// Used in request bodies sent to the Sessions Service.
/// Amounts are expressed as integers in the smallest currency unit (e.g. cents for EUR).
public struct AmountInMinor: Codable, Equatable, Sendable {
    public let amountInMinor: Int
    public let currency: String

    public init(amountInMinor: Int, currency: String) {
        self.amountInMinor = amountInMinor
        self.currency = currency
    }
}

/// Used in session response fields such as paymentAmount and remainingAmount.
/// The Sessions Service returns amounts as decimal strings (e.g. "10.00").
public struct AmountDecimal: Decodable, Equatable, Sendable {
    public let value: String
    public let currency: String

    private enum CodingKeys: String, CodingKey {
        case value = "amount"
        case currency
    }
}
