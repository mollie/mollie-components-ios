import MollieCore
import XCTest

// Intentionally NOT @testable — this suite exists to validate the public
// surface a third-party merchant sees. If a symbol referenced below stops
// resolving without @testable, that IS the regression we want to catch.
import MollieComponents
#if canImport(UIKit)
    import UIKit
#endif

final class PublicSurfaceTests: XCTestCase {
    // MARK: - Sendable conformance (compile-time)

    //
    // The cast to `any Sendable` fails to compile if the type is not Sendable,
    // catching accidental introduction of non-Sendable stored properties.

    func test_molliePaymentResult_cancelled_isSendable() {
        let _: any Sendable = MolliePaymentResult.cancelled
    }

    func test_molliePaymentResult_completed_isSendable() {
        let payment = MolliePayment(sessionToken: "tr_test", amount: "10.00", currency: "EUR")
        let _: any Sendable = MolliePaymentResult.completed(payment)
    }

    func test_molliePayment_isSendable() {
        let _: any Sendable = MolliePayment(sessionToken: "tr_test", amount: "10.00", currency: "EUR")
    }

    // MARK: - MolliePayment value semantics

    //
    // The merchant pattern-matches on .completed(payment) and reads these
    // fields; a typo here is a breaking API change.

    func test_molliePayment_exposesSessionTokenAmountCurrency() {
        let payment = MolliePayment(sessionToken: "tr_abc", amount: "12.34", currency: "EUR")
        XCTAssertEqual(payment.sessionToken, "tr_abc")
        XCTAssertEqual(payment.amount, "12.34")
        XCTAssertEqual(payment.currency, "EUR")
    }

    // MARK: - MollieCheckout public surface behaviour

    //
    // `MollieCheckout` is the session/factory type that vends
    // the card component both ways. This suite is intentionally NOT
    // @testable — it exists to pin down what a third-party merchant sees.
    //
    // `MollieCheckout` itself is defined under `#if canImport(UIKit)` (it
    // vends a UIKit presentation path), so these tests are gated the same
    // way — otherwise a plain macOS host build (e.g. `swift test` with no
    // destination) fails with "cannot find 'MollieCheckout' in scope".

    #if canImport(UIKit)
        func test_checkout_malformedClientToken_throwsInvalidClientToken() {
            XCTAssertThrowsError(try MollieCheckout(clientToken: "definitely-not-a-token")) { error in
                guard let mollieError = error as? MollieError, case .invalidClientToken = mollieError else {
                    XCTFail("Expected .invalidClientToken, got \(error)")
                    return
                }
            }
        }

        func test_checkout_validClientToken_exposesProductionEndpointsByDefault() throws {
            let json = """
            {
              "sessionToken": "sess_public",
              "secret": "shh",
              "availablePaymentMethods": ["creditcard"],
              "testmode": true,
              "profileToken": "pfl_public",
              "merchantProfileName": "Acme",
              "organizationCountryCode": "NL"
            }
            """
            let token = try XCTUnwrap(json.data(using: .utf8)?.base64EncodedString())
            let checkout = try MollieCheckout(clientToken: token)
            XCTAssertEqual(checkout.endpoints.sessionsBaseURL, MollieEndpoints.production.sessionsBaseURL)
        }
    #endif

    //
    // Compile-time assertion: `presentCard(from:)` is reachable without
    // @testable, and — critically — takes ONLY a host view controller. This
    // file only plain-imports MollieComponents (no MollieTesting SPI import),
    // so there is no way to spell a `theme:`/`endpoints:` argument here at
    // all; if either were ever restored to the public initializer/method
    // signatures, that reintroduction would show up as a compile error in
    // the SPI-gated call sites instead (see MollieCheckoutTests.swift),
    // never here. A future refactor that drops `public` or renames the
    // `from:` label breaks this closure's compile — which IS the regression
    // this test exists to catch.

    #if canImport(UIKit)
        @MainActor
        func test_checkoutPresentCardSignature_isAccessibleWithoutTestable() throws {
            let json = """
            {
              "sessionToken": "sess_public2",
              "secret": "shh",
              "availablePaymentMethods": ["creditcard"],
              "testmode": true,
              "profileToken": "pfl_public2",
              "merchantProfileName": "Acme",
              "organizationCountryCode": "NL"
            }
            """
            let token = try XCTUnwrap(json.data(using: .utf8)?.base64EncodedString())
            let checkout = try MollieCheckout(clientToken: token)
            let signature: (UIViewController) async -> MolliePaymentResult = {
                await checkout.presentCard(from: $0)
            }
            XCTAssertNotNil(signature as Any)
        }
    #endif

    // MARK: - MollieCheckout public init shape

    //
    // Compile-time assertion: the public initializer takes exactly
    // `clientToken`, `locale` (defaulted), and `beforeSubmit` (defaulted) —
    // no `theme`/`appearance`, no `endpoints`. Pinning the closure to this
    // exact three-argument shape means the suite fails to compile the
    // moment either forbidden parameter is reintroduced as a required
    // argument on the public init.

    #if canImport(UIKit)
        func test_checkoutInitSignature_hasNoAppearanceOrEndpointsParams() {
            let signature: (String, Locale, (@Sendable () async throws -> MollieCustomerDetails?)?) throws
                -> MollieCheckout = { clientToken, locale, beforeSubmit in
                    try MollieCheckout(clientToken: clientToken, locale: locale, beforeSubmit: beforeSubmit)
                }
            XCTAssertNotNil(signature as Any)
        }

        // Compile-time assertion mirroring
        // `test_checkoutInitSignature_hasNoAppearanceOrEndpointsParams` for
        // the standalone `MollieCardComponent` public init: it takes exactly
        // `clientToken` and `onResult` — no `endpoints:` (that lives only on
        // the internal, SPI-gated overload). This file plain-imports
        // MollieComponents, so restoring `endpoints:` to the public init
        // would either break this closure's compile or leave the SPI-gated
        // call sites as the only place it can be spelled.
        #if canImport(SwiftUI)
            func test_cardComponentInitSignature_hasNoEndpointsParam() {
                let signature: (String, @escaping (MolliePaymentResult) -> Void)
                    -> MollieCardComponent = { clientToken, onResult in
                        MollieCardComponent(clientToken: clientToken, onResult: onResult)
                    }
                XCTAssertNotNil(signature as Any)
            }
        #endif

        func test_checkout_defaultsToCurrentLocale() throws {
            let json = """
            {
              "sessionToken": "sess_public3",
              "secret": "shh",
              "availablePaymentMethods": ["creditcard"],
              "testmode": true,
              "profileToken": "pfl_public3",
              "merchantProfileName": "Acme",
              "organizationCountryCode": "NL"
            }
            """
            let token = try XCTUnwrap(json.data(using: .utf8)?.base64EncodedString())
            let checkout = try MollieCheckout(clientToken: token)
            XCTAssertEqual(checkout.locale, Locale.current)
        }
    #endif

    // MARK: - MollieCardFieldEvent public surface

    //
    // These four types are the SDK's public API surface for per-field
    // observability on the card form. They're plain value types
    // with no UIKit dependency, so — unlike the rest of this file — these
    // tests run ungated on every platform `swift test` targets.

    func test_mollieCardFieldEvent_isSendableAndEquatable() {
        let event = MollieCardFieldEvent(field: .cardNumber, isValid: true)
        let _: any Sendable = event
        XCTAssertEqual(event, MollieCardFieldEvent(field: .cardNumber, isValid: true))
    }

    func test_mollieCardFieldEvent_exposesFieldIsValidErrorKindDetectedScheme() {
        let event = MollieCardFieldEvent(
            field: .securityCode,
            isValid: false,
            errorKind: .invalidSecurityCode,
            detectedScheme: .visa
        )
        XCTAssertEqual(event.field, .securityCode)
        XCTAssertFalse(event.isValid)
        XCTAssertEqual(event.errorKind, .invalidSecurityCode)
        XCTAssertEqual(event.detectedScheme, .visa)
    }

    //
    // Compile-time assertion: every case a merchant needs to switch over
    // exists with the exact spelling below. If a case is renamed or removed,
    // this switch stops being exhaustive and the file fails to compile.

    func test_mollieCardField_hasAllFourCases() {
        func exhaustive(_ field: MollieCardField) {
            switch field {
            case .cardNumber, .expiryDate, .securityCode, .cardholderName: break
            }
        }
        exhaustive(.cardNumber)
    }

    func test_mollieCardScheme_hasAllExpectedCases() {
        func exhaustive(_ scheme: MollieCardScheme) {
            switch scheme {
            case .visa, .mastercard, .amex, .maestro, .discover,
                 .dinersClub, .jcb, .unionPay, .cartesBancaires, .other:
                break
            }
        }
        exhaustive(.visa)
        XCTAssertEqual(MollieCardScheme.other("sodexo"), MollieCardScheme.other("sodexo"))
    }

    func test_mollieCardFieldErrorKind_hasAllFourCases() {
        func exhaustive(_ kind: MollieCardFieldErrorKind) {
            switch kind {
            case .empty, .invalidNumber, .invalidExpiry, .invalidSecurityCode: break
            }
        }
        exhaustive(.empty)
    }

    #if canImport(UIKit) && canImport(SwiftUI)
        //
        // Compile-time assertion: `MollieCardComponent`'s public init accepts
        // an `onFieldEvent` closure alongside the existing `onResult`,
        // additive to the prior two-argument shape.

        func test_mollieCardComponentInit_acceptsOnFieldEventClosure() {
            // Direct construction (rather than a standalone signature
            // closure) sidesteps an escaping/non-escaping mismatch while
            // still pinning the compile-time shape: if `onFieldEvent` were
            // ever renamed or removed from the public init, this line stops
            // compiling.
            let component = MollieCardComponent(
                clientToken: "not-a-real-token",
                onFieldEvent: { (_: MollieCardFieldEvent) in },
                onResult: { (_: MolliePaymentResult) in }
            )
            XCTAssertNotNil(component as Any)
        }
    #endif
}
