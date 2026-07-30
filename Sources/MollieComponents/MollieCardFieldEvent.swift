import MolliePayments
import MolliePaymentsUI

/// Which field of the Mollie card form a ``MollieCardFieldEvent`` refers to.
public enum MollieCardField: Sendable, Equatable {
    case cardNumber
    case expiryDate
    case securityCode
    case cardholderName
}

/// Card network detected from the current card number, mirroring the
/// networks the SDK's local IIN table (and, when injected, an IIN look-up
/// service) can identify.
public enum MollieCardScheme: Sendable, Equatable {
    case visa
    case mastercard
    case amex
    case maestro
    case discover
    case dinersClub
    case jcb
    case unionPay
    case cartesBancaires
    /// A network the SDK detected but doesn't have a dedicated case for.
    /// `rawValue` mirrors whatever identifier the detection source used.
    case other(String)
}

/// Why a card-form field currently fails validation, as surfaced on
/// ``MollieCardFieldEvent/errorKind``.
public enum MollieCardFieldErrorKind: Sendable, Equatable {
    /// The cardholder name field is empty.
    case empty
    /// The card number is too short, too long, or fails the Luhn check.
    case invalidNumber
    /// The expiry date is malformed, out of range, or already in the past.
    case invalidExpiry
    /// The security code (CVC/CVV) is the wrong length or non-numeric.
    case invalidSecurityCode
}

/// Snapshot of a single card-form field's state, delivered every time the
/// cardholder edits or leaves (blurs) a field — see
/// ``MollieCardComponent/onFieldEvent``.
///
/// This is the SDK's public event surface for per-field
/// observability: a host can use it to drive its own
/// live validation UI, a card-scheme icon outside the SDK's own form, or
/// analytics — without the SDK exposing its internal `CardField`/
/// `CardScheme` types.
public struct MollieCardFieldEvent: Sendable, Equatable {
    /// Which field changed.
    public let field: MollieCardField
    /// Whether `field`'s current value passes validation.
    public let isValid: Bool
    /// The reason `field` is invalid. Always `nil` when `isValid` is `true`.
    public let errorKind: MollieCardFieldErrorKind?
    /// The card network detected from the current card number, if any.
    /// Reported alongside every field's event (not just `.cardNumber`'s) so
    /// a host doesn't need to separately track the card-number field just
    /// to read the detected scheme.
    public let detectedScheme: MollieCardScheme?

    public init(
        field: MollieCardField,
        isValid: Bool,
        errorKind: MollieCardFieldErrorKind? = nil,
        detectedScheme: MollieCardScheme? = nil
    ) {
        self.field = field
        self.isValid = isValid
        self.errorKind = errorKind
        self.detectedScheme = detectedScheme
    }
}

// MARK: - Internal <-> public mapping

/// Maps `MolliePaymentsUI`'s package-private `CardField` onto its public
/// mirror. Kept here (not in `MolliePaymentsUI`) so the internal type never
/// needs to become `public` — see `CardFieldEvent`'s doc comment.
extension MollieCardField {
    init(_ field: CardField) {
        switch field {
        case .pan: self = .cardNumber
        case .expiry: self = .expiryDate
        case .cvc: self = .securityCode
        case .cardholder: self = .cardholderName
        }
    }
}

/// Maps `MolliePayments`'s package-private `CardScheme` onto its public
/// mirror.
extension MollieCardScheme {
    init(_ scheme: CardScheme) {
        switch scheme {
        case .visa: self = .visa
        case .mastercard: self = .mastercard
        case .amex: self = .amex
        case .maestro: self = .maestro
        case .discover: self = .discover
        case .dinersClub: self = .dinersClub
        case .jcb: self = .jcb
        case .unionPay: self = .unionPay
        case .cartesBancaires: self = .cartesBancaires
        case let .other(raw): self = .other(raw)
        }
    }
}

/// Maps `CardFormValidator.ValidationError` onto the public error-kind
/// mirror. Collapses the validator's per-cause cases (`panTooShort` /
/// `panTooLong` / `panFailsLuhn`, the various `ExpiryParser.ParseError`
/// reasons) down to one kind per field — the public surface intentionally
/// stays coarser than the internal validator; a host wanting the exact
/// reason still gets it via the SDK's own inline caption UI.
extension MollieCardFieldErrorKind {
    init(_ error: CardFormValidator.ValidationError) {
        switch error {
        case .missingCardholder: self = .empty
        case .panTooShort, .panTooLong, .panFailsLuhn: self = .invalidNumber
        case .expiry: self = .invalidExpiry
        case .cvcWrongLength: self = .invalidSecurityCode
        }
    }
}

extension MollieCardFieldEvent {
    init(_ event: CardFieldEvent) {
        self.init(
            field: MollieCardField(event.field),
            isValid: event.isValid,
            errorKind: event.error.map(MollieCardFieldErrorKind.init),
            detectedScheme: event.detectedScheme.map(MollieCardScheme.init)
        )
    }
}
