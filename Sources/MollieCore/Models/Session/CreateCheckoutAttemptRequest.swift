public struct CreateCheckoutAttemptRequest: Encodable, Sendable {
    public let paymentMethod: String
    public let checkoutMethod: String
    public let fingerprint: DeviceFingerprint
    public let pspToken: String?
    public let wallet: String?
    public let walletToken: String?
    /// Customer billing/shipping details injected via `MollieCheckout`'s
    /// `beforeSubmit` hook. Omitted from the wire body when nil (see
    /// `MollieCustomerDetails`).
    public let customerDetails: MollieCustomerDetails?

    public init(
        paymentMethod: String,
        checkoutMethod: String,
        fingerprint: DeviceFingerprint,
        pspToken: String?,
        wallet: String?,
        walletToken: String?,
        customerDetails: MollieCustomerDetails? = nil
    ) {
        self.paymentMethod = paymentMethod
        self.checkoutMethod = checkoutMethod
        self.fingerprint = fingerprint
        self.pspToken = pspToken
        self.wallet = wallet
        self.walletToken = walletToken
        self.customerDetails = customerDetails
    }
}
