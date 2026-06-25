import Foundation

/// Strongly-typed identifier for the offending card-form field. Replaces a
/// scattering of `"cardholderName"` / `"cardNumber"` string literals that
/// drifted between the validator and the focus-routing switch in
/// `MollieCardFormViewController`. Raw values are kept for back-compat with
/// any caller that reads `ValidationError.field` as a `String` (matches the
/// previous literals exactly).
package enum CardField: String {
    case cardholder = "cardholderName"
    case pan = "cardNumber"
    case expiry
    case cvc
}

/// Submit-time validation for the card form snapshot. Returns the first
/// problem (form surfaces it in an alert) or `.success` if every field
/// passes. Defense-in-depth: `PaymentSheetCoordinator` runs the same
/// validation after the form's check so a future caller that bypasses
/// the form still gets a typed failure.
package enum CardFormValidator {
    package enum ValidationError: Error, Equatable {
        case missingCardholder
        case panTooShort
        case panTooLong
        case panFailsLuhn
        case expiry(ExpiryParser.ParseError)
        case cvcWrongLength

        /// Short, merchant-presentable error string. Localisation lands when
        /// the form gets a Localizable.strings table; for now this is the
        /// canonical English form, sufficient for MR5's alert and any test
        /// assertion that needs to inspect the message verbatim.
        package var userMessage: String {
            switch self {
            case .missingCardholder: "Enter the name on your card."
            case .panTooShort: "Your card number looks too short."
            case .panTooLong: "Your card number looks too long."
            case .panFailsLuhn: "Check your card number for typos."
            case let .expiry(reason): Self.expiryMessage(reason)
            case .cvcWrongLength: "CVC must be 3 or 4 digits."
            }
        }

        /// Stable identifier for the offending field, suitable for mapping
        /// into `MollieError.invalidConfiguration(field:)`. Kept as `String`
        /// for back-compat; use `fieldKind` for the typed form.
        package var field: String {
            fieldKind.rawValue
        }

        /// Strongly-typed flavour of `field` for in-package call-sites that
        /// would otherwise switch on raw string literals.
        package var fieldKind: CardField {
            switch self {
            case .missingCardholder: .cardholder
            case .panTooShort, .panTooLong, .panFailsLuhn: .pan
            case .expiry: .expiry
            case .cvcWrongLength: .cvc
            }
        }

        private static func expiryMessage(_ reason: ExpiryParser.ParseError) -> String {
            switch reason {
            case .malformed: "Enter expiry as MM/YY."
            case .monthOutOfRange: "Expiry month must be between 01 and 12."
            case .pastMonth: "Expiry date has passed."
            case .farFuture: "Check the expiry date."
            }
        }
    }

    /// Returns the first validation error, or `nil` if the snapshot is good
    /// to submit. Nil-as-success keeps the assertion API equatable; tests
    /// can `XCTAssertNil(...)` happy paths and `XCTAssertEqual(..., .x)`
    /// failure cases without dragging in `Result<Void, _>` shenanigans.
    package static func validate(snapshot: CardFormSnapshot) -> ValidationError? {
        let trimmedName = snapshot.cardholderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return .missingCardholder }

        // Strip everything that isn't an ASCII digit. The previous
        // `!$0.isWhitespace` filter let through hyphens (from
        // `4242-4242-4242-4242` pastes), NBSPs (clipboard normalisation),
        // and non-ASCII numeric shapes (Arabic-Indic digits satisfy
        // `isNumber` but the tokeniser rejects them). ASCII-digit-only
        // normalises every variant the user can paste into a canonical
        // digit run.
        let pan = snapshot.cardNumber.filter { $0.isASCII && $0.isNumber }
        // 13 / 19 are the PCI lower / upper bounds for issuer-assigned PANs.
        // Out-of-range catches typos before they cost a tokeniser round-trip.
        if pan.count < 13 { return .panTooShort }
        if pan.count > 19 { return .panTooLong }
        guard Luhn.isValid(pan) else { return .panFailsLuhn }

        if case let .failure(reason) = ExpiryParser.parse(snapshot.expiry) {
            return .expiry(reason)
        }

        let cvc = snapshot.cvc.filter { !$0.isWhitespace }
        // 3 (Visa/MC) or 4 (Amex) — IIN-driven precise length lands when the
        // form gets IIN integration in a follow-up. Until then, accept both.
        // ASCII-gated to reject non-Latin digit shapes (e.g. Arabic-Indic
        // digits satisfy `isNumber` but the tokeniser would reject them).
        if cvc.count < 3 || cvc.count > 4 || !cvc.allSatisfy({ $0.isASCII && $0.isNumber }) {
            return .cvcWrongLength
        }

        return nil
    }
}
