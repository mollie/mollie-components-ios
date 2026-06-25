import MollieCore
import MolliePaymentsUI
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

    func test_molliePaymentTheme_isSendable() {
        let _: any Sendable = MolliePaymentTheme()
    }

    // MARK: - MolliePaymentSheet public surface behaviour

    //
    // Bad client token resolves through the public entry point as
    // .failed(.invalidClientToken) — never .cancelled (that was the MR1 stub
    // contract). This guards both the short-circuit in the coordinator and
    // the visibility of MollieError.invalidClientToken on the public surface.

    @MainActor
    func test_present_malformedClientToken_returnsFailed() async {
        #if canImport(UIKit)
            let host = UIViewController()
            let result = await MolliePaymentSheet.present(
                from: host,
                clientToken: "definitely-not-a-token",
                theme: MolliePaymentTheme()
            )
            guard case .failed = result else {
                XCTFail("Malformed client token must return .failed; got \(result)")
                return
            }
        #endif
    }

    @MainActor
    func test_present_malformedClientToken_failsWithInvalidClientToken() async {
        #if canImport(UIKit)
            let host = UIViewController()
            let result = await MolliePaymentSheet.present(
                from: host,
                clientToken: "definitely-not-a-token",
                theme: MolliePaymentTheme()
            )
            guard case let .failed(error) = result else {
                XCTFail("Expected .failed, got \(result)")
                return
            }
            guard case .invalidClientToken = error else {
                XCTFail("Expected .invalidClientToken, got \(error)")
                return
            }
        #endif
    }

    //
    // Compile-time assertion: the public present(from:clientToken:theme:)
    // signature is reachable without @testable. If a future refactor
    // accidentally drops `public` or renames a label, the type below stops
    // resolving and the suite fails to compile — which IS the regression we
    // want to catch.

    #if canImport(UIKit)
        @MainActor
        func test_presentSignature_isAccessibleWithoutTestable() {
            let signature: (UIViewController, String, MolliePaymentTheme) async -> MolliePaymentResult =
                MolliePaymentSheet.present(from:clientToken:theme:)
            // The load-bearing part is that the assignment above compiles
            // without @testable. The runtime check just ensures the test is
            // discovered as a non-trivial body by XCTest's runtime scan.
            XCTAssertNotNil(signature as Any)
        }
    #endif

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
}
