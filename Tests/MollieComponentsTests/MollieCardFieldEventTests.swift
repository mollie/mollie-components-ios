import XCTest
@testable import MollieComponents
@testable import MolliePayments
@testable import MolliePaymentsUI

/// Covers the internal `CardField`/`CardScheme`/`CardFormValidator
/// .ValidationError` → public `MollieCardField`/`MollieCardScheme`/
/// `MollieCardFieldErrorKind` mapping. `@testable`
/// (unlike `PublicSurfaceTests`) because the mapping initializers are
/// package/internal — a third-party merchant never calls them directly, so
/// they don't belong in the public-surface suite.
final class MollieCardFieldEventTests: XCTestCase {
    // MARK: - MollieCardField

    func test_mollieCardField_mapsEveryCardFieldCase() {
        XCTAssertEqual(MollieCardField(.pan), .cardNumber)
        XCTAssertEqual(MollieCardField(.expiry), .expiryDate)
        XCTAssertEqual(MollieCardField(.cvc), .securityCode)
        XCTAssertEqual(MollieCardField(.cardholder), .cardholderName)
    }

    // MARK: - MollieCardScheme

    func test_mollieCardScheme_mapsEveryNamedCardSchemeCase() {
        XCTAssertEqual(MollieCardScheme(.visa), .visa)
        XCTAssertEqual(MollieCardScheme(.mastercard), .mastercard)
        XCTAssertEqual(MollieCardScheme(.amex), .amex)
        XCTAssertEqual(MollieCardScheme(.maestro), .maestro)
        XCTAssertEqual(MollieCardScheme(.discover), .discover)
        XCTAssertEqual(MollieCardScheme(.dinersClub), .dinersClub)
        XCTAssertEqual(MollieCardScheme(.jcb), .jcb)
        XCTAssertEqual(MollieCardScheme(.unionPay), .unionPay)
        XCTAssertEqual(MollieCardScheme(.cartesBancaires), .cartesBancaires)
    }

    func test_mollieCardScheme_mapsOtherCasePreservingRawValue() {
        XCTAssertEqual(MollieCardScheme(.other("sodexo")), .other("sodexo"))
    }

    // MARK: - MollieCardFieldErrorKind

    func test_mollieCardFieldErrorKind_mapsMissingCardholderToEmpty() {
        XCTAssertEqual(MollieCardFieldErrorKind(.missingCardholder), .empty)
    }

    func test_mollieCardFieldErrorKind_mapsEveryPanCauseToInvalidNumber() {
        XCTAssertEqual(MollieCardFieldErrorKind(.panTooShort), .invalidNumber)
        XCTAssertEqual(MollieCardFieldErrorKind(.panTooLong), .invalidNumber)
        XCTAssertEqual(MollieCardFieldErrorKind(.panFailsLuhn), .invalidNumber)
    }

    func test_mollieCardFieldErrorKind_mapsExpiryToInvalidExpiry() {
        XCTAssertEqual(MollieCardFieldErrorKind(.expiry(.malformed)), .invalidExpiry)
    }

    func test_mollieCardFieldErrorKind_mapsCvcWrongLengthToInvalidSecurityCode() {
        XCTAssertEqual(MollieCardFieldErrorKind(.cvcWrongLength), .invalidSecurityCode)
    }

    // MARK: - MollieCardFieldEvent

    func test_mollieCardFieldEvent_mapsValidCardFieldEvent() {
        let internalEvent = CardFieldEvent(field: .pan, isValid: true, error: nil, detectedScheme: .visa)

        let publicEvent = MollieCardFieldEvent(internalEvent)

        XCTAssertEqual(publicEvent.field, .cardNumber)
        XCTAssertTrue(publicEvent.isValid)
        XCTAssertNil(publicEvent.errorKind)
        XCTAssertEqual(publicEvent.detectedScheme, .visa)
    }

    func test_mollieCardFieldEvent_mapsInvalidCardFieldEventWithErrorKind() {
        let internalEvent = CardFieldEvent(
            field: .cvc,
            isValid: false,
            error: .cvcWrongLength,
            detectedScheme: nil
        )

        let publicEvent = MollieCardFieldEvent(internalEvent)

        XCTAssertEqual(publicEvent.field, .securityCode)
        XCTAssertFalse(publicEvent.isValid)
        XCTAssertEqual(publicEvent.errorKind, .invalidSecurityCode)
        XCTAssertNil(publicEvent.detectedScheme)
    }
}
