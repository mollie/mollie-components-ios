public struct CardSubmissionData: Equatable {
    public let cardholderName: String?
    public let cardNumber: String
    public let expiryMonth: Int
    public let expiryYear: Int
    public let cvc: String

    public init(cardholderName: String?, cardNumber: String, expiryMonth: Int, expiryYear: Int, cvc: String) {
        self.cardholderName = cardholderName
        self.cardNumber = cardNumber
        self.expiryMonth = expiryMonth
        self.expiryYear = expiryYear
        self.cvc = cvc
    }
}
