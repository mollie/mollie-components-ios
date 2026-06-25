/// A successfully completed Mollie payment as surfaced to the merchant.
///
/// Stub for MR1: holds the minimum identifying fields a merchant needs to
/// reconcile the result with their backend. MR3 wires the real mapping
/// from `SessionResponse`; additional fields (status, method, metadata)
/// will be added there as needed and on demand.
public struct MolliePayment: Sendable, Equatable {
    /// Session token (the `sessionToken` returned by the Sessions Service
    /// on the completed session). This is the merchant's reconciliation
    /// handle today; a richer server-side payment id (`tr_xxx`) will be
    /// added as a separate field once the Sessions Service surfaces it on
    /// the completed event.
    public let sessionToken: String

    /// Payment amount as a decimal string (e.g. `"10.00"`). Matches the
    /// `AmountDecimal.value` shape returned by the Sessions Service.
    public let amount: String

    /// ISO 4217 currency code (e.g. `"EUR"`).
    public let currency: String

    public init(sessionToken: String, amount: String, currency: String) {
        self.sessionToken = sessionToken
        self.amount = amount
        self.currency = currency
    }
}
