public enum PaymentMethodType: String, Decodable, Equatable, Sendable {
    case creditCard = "creditcard"
    case applePay = "applepay"
    case bancontact
    case bankTransfer = "banktransfer"
    case belfius
    case blik
    case directDebit = "directdebit"
    case eps
    case giftCard = "giftcard"
    case googlePay = "googlepay"
    case ideal
    case idealCheckout = "idealcheckout"
    case kbc
    case klarnaPayLater = "klarnapaylater"
    case klarnaPayNow = "klarnapaynow"
    case klarnaSliceIt = "klarnasliceit"
    case mbway
    case multibanco
    case mybank
    case payByBank = "paybybank"
    case paypal
    case paysafecard
    case przelewy24
    case satispay
    case swish
    case twint
    case voucher
    case bancomatPay = "bancomatpay"
}
