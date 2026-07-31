import Foundation
import MolliePayments

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

/// Snapshot of a single card-form field's live state, delivered by
/// `MollieCardFormViewController.onFieldEvent` on every edit/blur.
/// Intentionally undocumented outside the package —
/// `MollieComponents` maps this to the public `MollieCardFieldEvent`
/// mirror so merchants never see `CardField`/`CardScheme` directly. Declared
/// here (not in `MollieCardFormViewController.swift`) so it stays available
/// on platforms where that file's `#if canImport(UIKit)` gate compiles out.
package struct CardFieldEvent: Equatable {
    package let field: CardField
    package let isValid: Bool
    package let error: CardFormValidator.ValidationError?
    package let detectedScheme: CardScheme?

    package init(
        field: CardField,
        isValid: Bool,
        error: CardFormValidator.ValidationError?,
        detectedScheme: CardScheme?
    ) {
        self.field = field
        self.isValid = isValid
        self.error = error
        self.detectedScheme = detectedScheme
    }
}

/// Submit-time validation for the card form snapshot. Returns the first
/// problem (form surfaces it in an alert) or `.success` if every field
/// passes. Defense-in-depth: `CardCheckoutRunner.parse(snapshot:)` runs the
/// same validation after the form's check so a future caller that bypasses
/// the form still gets a typed failure.
package enum CardFormValidator {
    package enum ValidationError: Error, Equatable {
        case missingCardholder
        case panTooShort
        case panTooLong
        case panFailsLuhn
        case expiry(ExpiryParser.ParseError)
        case cvcWrongLength

        /// Short, merchant-presentable error string, localized via
        /// MolliePaymentsUI's `Localizable.strings`, using the system's
        /// default bundle-selection. Kept for callers that predate the
        /// locale-threading work; delegates to `userMessage(bundle:)`.
        package var userMessage: String {
            userMessage(bundle: nil)
        }

        /// Short, merchant-presentable error string, localized via
        /// MolliePaymentsUI's `Localizable.strings`. Also feeds the
        /// per-field inline error captions (`MollieGroupedCardFormView`),
        /// so this is the single source for both the alert and the
        /// inline captions. `bundle`, when supplied, is the locale-specific
        /// `.lproj` sub-bundle the merchant's resolved locale maps to
        /// (`nil` keeps the default system-preferred-language behaviour).
        package func userMessage(bundle: Bundle?) -> String {
            switch self {
            case .missingCardholder:
                MollieLocalizedString(
                    "validation.cardholder.empty",
                    bundle: bundle,
                    comment: "Validation message shown when the cardholder-name field is empty."
                )
            case .panTooShort:
                MollieLocalizedString(
                    "validation.number.tooShort",
                    bundle: bundle,
                    comment: "Validation message shown when the card number has too few digits."
                )
            case .panTooLong:
                MollieLocalizedString(
                    "validation.number.tooLong",
                    bundle: bundle,
                    comment: "Validation message shown when the card number has too many digits."
                )
            case .panFailsLuhn:
                MollieLocalizedString(
                    "validation.number.invalid",
                    bundle: bundle,
                    comment: "Validation message shown when the card number fails the Luhn checksum."
                )
            case let .expiry(reason): Self.expiryMessage(reason, bundle: bundle)
            case .cvcWrongLength:
                MollieLocalizedString(
                    "validation.cvc.wrongLength",
                    bundle: bundle,
                    comment: "Validation message shown when the CVC is not 3 or 4 digits long."
                )
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

        private static func expiryMessage(_ reason: ExpiryParser.ParseError, bundle: Bundle?) -> String {
            switch reason {
            case .malformed:
                MollieLocalizedString(
                    "validation.expiry.malformed",
                    bundle: bundle,
                    comment: "Validation message shown when the expiry field doesn't match the MM/YY format."
                )
            case .monthOutOfRange:
                MollieLocalizedString(
                    "validation.expiry.monthOutOfRange",
                    bundle: bundle,
                    comment: "Validation message shown when the expiry month is not between 01 and 12."
                )
            case .pastMonth:
                MollieLocalizedString(
                    "validation.expiry.pastMonth",
                    bundle: bundle,
                    comment: "Validation message shown when the expiry date is in the past."
                )
            case .farFuture:
                MollieLocalizedString(
                    "validation.expiry.farFuture",
                    bundle: bundle,
                    comment: "Validation message shown when the expiry date is implausibly far in the future."
                )
            }
        }
    }

    /// Returns the first validation error, or `nil` if the snapshot is good
    /// to submit. Nil-as-success keeps the assertion API equatable; tests
    /// can `XCTAssertNil(...)` happy paths and `XCTAssertEqual(..., .x)`
    /// failure cases without dragging in `Result<Void, _>` shenanigans.
    package static func validate(snapshot: CardFormSnapshot) -> ValidationError? {
        if let error = cardholderError(snapshot) {
            return error
        }
        if let error = panError(snapshot) {
            return error
        }
        if let error = expiryError(snapshot) {
            return error
        }
        if let error = cvcError(snapshot) {
            return error
        }
        return nil
    }

    /// Returns every failing field's error, in `cardholder, pan, expiry,
    /// cvc` order, or `[]` if the snapshot is good to submit. Built for
    /// the multi-error summary UI, which needs to surface all
    /// problems at once rather than the single first-failure `validate(_:)`
    /// exposes to the live submit-button gate.
    package static func validateAll(snapshot: CardFormSnapshot) -> [ValidationError] {
        [
            cardholderError(snapshot),
            panError(snapshot),
            expiryError(snapshot),
            cvcError(snapshot),
        ].compactMap { $0 }
    }

    private static func cardholderError(_ snapshot: CardFormSnapshot) -> ValidationError? {
        let trimmedName = snapshot.cardholderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return .missingCardholder }
        return nil
    }

    private static func panError(_ snapshot: CardFormSnapshot) -> ValidationError? {
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
        if pan.count < 13 {
            return .panTooShort
        }
        if pan.count > 19 {
            return .panTooLong
        }
        guard Luhn.isValid(pan) else { return .panFailsLuhn }
        return nil
    }

    private static func expiryError(_ snapshot: CardFormSnapshot) -> ValidationError? {
        if case let .failure(reason) = ExpiryParser.parse(snapshot.expiry) {
            return .expiry(reason)
        }
        return nil
    }

    private static func cvcError(_ snapshot: CardFormSnapshot) -> ValidationError? {
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
