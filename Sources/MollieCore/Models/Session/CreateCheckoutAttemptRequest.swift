public struct CreateCheckoutAttemptRequest: Encodable, Sendable {
    public let paymentMethod: String
    public let checkoutMethod: String
    public let fingerprint: DeviceFingerprint
    public let pspToken: String?
    public let wallet: String?
    public let walletToken: String?

    public init(
        paymentMethod: String,
        checkoutMethod: String,
        fingerprint: DeviceFingerprint,
        pspToken: String?,
        wallet: String?,
        walletToken: String?
    ) {
        self.paymentMethod = paymentMethod
        self.checkoutMethod = checkoutMethod
        self.fingerprint = fingerprint
        self.pspToken = pspToken
        self.wallet = wallet
        self.walletToken = walletToken
    }
}
