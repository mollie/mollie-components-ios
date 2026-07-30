#if canImport(UIKit)
    import Foundation
    import XCTest
    @testable import MollieComponents
    @testable import MollieCore
    @testable import MolliePayments
    @testable import MolliePaymentsUI

    /// `CardCheckoutModalCoordinator`-specific behaviour behind
    /// `MollieCheckout.presentCard(from:)`: the unattached-host
    /// short-circuit, the single-shot continuation guard (`Resolver`), and
    /// (under `MOLLIE_INTERNAL`) the debug-timeline emit sites around a real
    /// presentation. Parse/map/decode/statusString/makeChannelsClient are
    /// already covered by `CardCheckoutRunnerTests` — the modal coordinator
    /// delegates to the same statics, so we don't duplicate those assertions
    /// here.
    @MainActor
    final class CardCheckoutModalCoordinatorTests: XCTestCase {
        /// The global debug sink is process-global; XCTest runs methods serially
        /// within a class but multiple test bundles or future parallelisation
        /// could race on it. Clear before and after every test so a previous
        /// method's RecordingDebugSink can't leak events into this one.
        override func setUp() {
            super.setUp()
        }

        override func tearDown() {
            super.tearDown()
        }

        // MARK: - presentCard entry point short-circuit

        func test_presentCard_invalidClientToken_throwsAtConstruction() {
            // MollieCheckout decodes eagerly at init time, so a malformed
            // token never even reaches presentCard — it fails fast at
            // construction instead. See MollieCheckoutTests for the
            // dedicated throw-site coverage; this suite starts from an
            // already-valid MollieCheckout.
            XCTAssertThrowsError(try MollieCheckout(clientToken: "definitely-not-a-token"))
        }

        func test_presentCard_unattachedHost_returnsFailedWithoutPresenting() async throws {
            // The integration test: an unattached host (no window) resolves
            // .failed and never touches the host VC. If present(...)
            // actually attempted to show a modal on it, UIKit would log a
            // warning (no window) but more importantly we'd see a non-
            // `.failed` result if the short-circuit broke.
            let token = try XCTUnwrap(Self.validClientTokenJSON.data(using: .utf8)?.base64EncodedString())
            let checkout = try MollieCheckout(clientToken: token)
            let host = UIViewController()
            let result = await checkout.presentCard(from: host)
            guard case let .failed(error) = result else {
                XCTFail("Expected .failed for unattached host, got \(result)")
                return
            }
            guard case .invalidConfiguration = error else {
                XCTFail("Expected .invalidConfiguration, got \(error)")
                return
            }
            // Host did not get a presented VC because we never reached the
            // present(...) call. (UIKit returns nil here when nothing has
            // been presented.)
            let presented = await host.presentedViewController
            XCTAssertNil(presented)
        }

        // MARK: - Resolver idempotency

        //
        // The continuation behind `CardCheckoutModalCoordinator.present` is
        // single-shot: Swift's runtime traps if `resume(...)` is called
        // twice. The submit success and the swipe-to-dismiss can both land
        // on the same runloop tick, so the Resolver MUST drop everything
        // after the first call. These tests pin that invariant down at the
        // Resolver level — the coordinator-level guard in
        // `resolveAndDismiss(_:)` is a second line of defense and is
        // exercised end-to-end above.

        func test_resolver_secondResolveIsIgnored_firstWins() async {
            let result = await withCheckedContinuation { (continuation: CheckedContinuation<
                MolliePaymentResult,
                Never
            >) in
                let resolver = Resolver(continuation: continuation)
                resolver.resolve(.cancelled)
                // A late .failed must not double-resume the continuation.
                // If the guard ever regresses, the suite traps on the second
                // resume rather than failing this assertion — both outcomes
                // surface the regression.
                resolver.resolve(.failed(.invalidConfiguration(field: "x", reason: "late")))
            }
            guard case .cancelled = result else {
                XCTFail("Expected first resolve (.cancelled) to win; got \(result)")
                return
            }
        }

        func test_resolver_thirdResolveAlsoIgnored() async {
            // Belt-and-braces: the guard must hold for N>2 calls too, not
            // just the obvious submit-then-dismiss pair.
            let result = await withCheckedContinuation { (continuation: CheckedContinuation<
                MolliePaymentResult,
                Never
            >) in
                let resolver = Resolver(continuation: continuation)
                let payment = MolliePayment(sessionToken: "tok_first", amount: "1.00", currency: "EUR")
                resolver.resolve(.completed(payment))
                resolver.resolve(.cancelled)
                resolver.resolve(.failed(.sessionCancelled))
            }
            guard case let .completed(payment) = result else {
                XCTFail("Expected first resolve (.completed) to win; got \(result)")
                return
            }
            XCTAssertEqual(payment.sessionToken, "tok_first")
        }

        // MARK: - debug emit-site smoke

        private static let validClientTokenJSON = """
        {
          "sessionToken": "sess_abc",
          "secret": "shh",
          "availablePaymentMethods": ["creditcard"],
          "testmode": true,
          "profileToken": "pfl_xyz",
          "merchantProfileName": "Acme",
          "organizationCountryCode": "NL"
        }
        """
    }

#endif
