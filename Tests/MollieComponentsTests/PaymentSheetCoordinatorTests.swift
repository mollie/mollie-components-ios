#if canImport(UIKit)
    import Foundation
    import XCTest
    @testable import MollieComponents
    @testable import MollieCore
    @testable import MolliePayments
    @testable import MolliePaymentsUI

    /// MR3 verification: clientToken decode error paths short-circuit
    /// before any UI presents, raw form input is parsed into a typed
    /// submission shape, and the engine's CardPaymentResult maps cleanly
    /// onto the merchant-facing MolliePaymentResult. End-to-end flows
    /// (real submit + 3DS) are covered by MR5 + MR8 — they require a
    /// running form behaviour layer that lands in MR5.
    @MainActor
    final class PaymentSheetCoordinatorTests: XCTestCase {
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

        // MARK: - clientToken decode

        func test_decode_validToken_returnsClientToken() throws {
            let json = """
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
            let token = try XCTUnwrap(json.data(using: .utf8)?.base64EncodedString())

            switch PaymentSheetCoordinator.decode(clientToken: token) {
            case let .success(decoded):
                XCTAssertEqual(decoded.sessionToken, "sess_abc")
                XCTAssertEqual(decoded.profileToken, "pfl_xyz")
                XCTAssertTrue(decoded.testmode)
            case let .failure(error):
                XCTFail("Expected success, got failure: \(error)")
            }
        }

        func test_decode_invalidBase64_returnsInvalidClientToken() {
            // Regression target: a malformed token must surface as a typed
            // .invalidClientToken so the sheet can return .failed BEFORE any
            // UI presents — not a generic .unknown that the merchant can't
            // pattern-match.
            switch PaymentSheetCoordinator.decode(clientToken: "not-valid-base64-@@@") {
            case .success:
                XCTFail("Expected failure for malformed base64")
            case let .failure(error):
                guard case .invalidClientToken = error else {
                    XCTFail("Expected .invalidClientToken, got \(error)")
                    return
                }
            }
        }

        func test_decode_emptyString_returnsInvalidClientToken() {
            // Regression: when isPresented and clientToken are updated in the
            // same SwiftUI state batch, the .onChange closure captures the
            // stale clientToken="" from the previous render. Data(base64Encoded:"")
            // returns empty Data, which JSONDecoder decodes as dataCorrupted.
            // The fix is to use .task(id: isPresented) which re-creates the task
            // after the view re-renders with both state changes applied.
            switch PaymentSheetCoordinator.decode(clientToken: "") {
            case .success:
                XCTFail("Expected failure for empty clientToken")
            case let .failure(error):
                guard case .invalidClientToken = error else {
                    XCTFail("Expected .invalidClientToken, got \(error)")
                    return
                }
            }
        }

        func test_decode_validBase64ButNotJSON_returnsInvalidClientToken() {
            let token = Data("this is not json".utf8).base64EncodedString()
            switch PaymentSheetCoordinator.decode(clientToken: token) {
            case .success:
                XCTFail("Expected failure for non-JSON body")
            case let .failure(error):
                guard case .invalidClientToken = error else {
                    XCTFail("Expected .invalidClientToken, got \(error)")
                    return
                }
            }
        }

        func test_decode_jsonMissingRequiredField_returnsInvalidClientToken() throws {
            // Missing profileToken — should fail rather than silently produce
            // a half-built ClientToken.
            let json = """
            {
              "sessionToken": "sess_abc",
              "secret": "shh",
              "availablePaymentMethods": [],
              "testmode": false
            }
            """
            let token = try XCTUnwrap(json.data(using: .utf8)?.base64EncodedString())
            switch PaymentSheetCoordinator.decode(clientToken: token) {
            case .success:
                XCTFail("Expected failure for missing required field")
            case let .failure(error):
                guard case .invalidClientToken = error else {
                    XCTFail("Expected .invalidClientToken, got \(error)")
                    return
                }
            }
        }

        // MARK: - snapshot → CardSubmissionData

        func test_parse_validSnapshot_producesSubmission() {
            let snapshot = CardFormSnapshot(
                cardholderName: "Ada Lovelace",
                cardNumber: "4242 4242 4242 4242",
                expiry: "12/30",
                cvc: "123"
            )
            switch PaymentSheetCoordinator.parse(snapshot: snapshot) {
            case let .success(submission):
                XCTAssertEqual(submission.cardholderName, "Ada Lovelace")
                // Whitespace stripped from PAN before tokenisation.
                XCTAssertEqual(submission.cardNumber, "4242424242424242")
                XCTAssertEqual(submission.expiryMonth, 12)
                // Two-digit year expanded to four with the 2000 epoch — matches
                // every PAN expiry the form will see.
                XCTAssertEqual(submission.expiryYear, 2030)
                XCTAssertEqual(submission.cvc, "123")
            case let .failure(error):
                XCTFail("Expected success, got \(error)")
            }
        }

        func test_parse_fourDigitYear_passesThrough() {
            // Merchant code generating tokens directly might emit MM/YYYY.
            // Don't double-add 2000 to a year that's already four digits.
            let snapshot = CardFormSnapshot(
                cardholderName: "Ada",
                cardNumber: "4242424242424242",
                expiry: "01/2040",
                cvc: "999"
            )
            switch PaymentSheetCoordinator.parse(snapshot: snapshot) {
            case let .success(submission):
                XCTAssertEqual(submission.expiryYear, 2040)
            case let .failure(error):
                XCTFail("Expected success, got \(error)")
            }
        }

        func test_parse_emptyPAN_returnsInvalidConfiguration() {
            let snapshot = CardFormSnapshot(
                cardholderName: "Ada",
                cardNumber: "   ",
                expiry: "12/30",
                cvc: "123"
            )
            switch PaymentSheetCoordinator.parse(snapshot: snapshot) {
            case .success:
                XCTFail("Expected failure for empty PAN")
            case let .failure(error):
                guard case let .invalidConfiguration(field, _) = error else {
                    XCTFail("Expected .invalidConfiguration, got \(error)")
                    return
                }
                XCTAssertEqual(field, "cardNumber")
            }
        }

        func test_parse_malformedExpiry_returnsInvalidConfiguration() {
            // Missing slash: validator catches via .expiry(.malformed) and the
            // parser maps it to .invalidConfiguration(field: "expiry").
            let snapshot = CardFormSnapshot(
                cardholderName: "Ada",
                cardNumber: "4242424242424242",
                expiry: "1230",
                cvc: "123"
            )
            switch PaymentSheetCoordinator.parse(snapshot: snapshot) {
            case .success:
                XCTFail("Expected failure for malformed expiry")
            case let .failure(error):
                guard case let .invalidConfiguration(field, _) = error else {
                    XCTFail("Expected .invalidConfiguration, got \(error)")
                    return
                }
                XCTAssertEqual(field, "expiry")
            }
        }

        // MARK: - CardPaymentResult → MolliePaymentResult mapping

        func test_map_completed_carriesSessionTokenAndAmount() throws {
            let json = """
            {
              "sessionToken": "sess_abc",
              "status": "completed",
              "nextAction": {"actionType": "await"},
              "paymentAmount": {"amount": "10.00", "currency": "EUR"}
            }
            """
            let session = try MollieJSONDecoder().decode(SessionResponse.self, from: Data(json.utf8))
            let mapped = PaymentSheetCoordinator.map(cardResult: .completed(session))
            guard case let .completed(payment) = mapped else {
                XCTFail("Expected .completed, got \(mapped)")
                return
            }
            // sessionToken is the merchant's reconciliation handle until the
            // backend surfaces a richer payment id on the completed event.
            XCTAssertEqual(payment.sessionToken, "sess_abc")
            XCTAssertEqual(payment.amount, "10.00")
            XCTAssertEqual(payment.currency, "EUR")
        }

        func test_map_failed_propagatesError() {
            let mapped = PaymentSheetCoordinator.map(
                cardResult: .failed(.invalidConfiguration(field: "x", reason: "y"))
            )
            guard case let .failed(error) = mapped,
                  case let .invalidConfiguration(field, _) = error
            else {
                XCTFail("Expected .failed(.invalidConfiguration), got \(mapped)")
                return
            }
            XCTAssertEqual(field, "x")
        }

        func test_map_cancelled_returnsCancelled() {
            let mapped = PaymentSheetCoordinator.map(cardResult: .cancelled)
            guard case .cancelled = mapped else {
                XCTFail("Expected .cancelled, got \(mapped)")
                return
            }
        }

        // MARK: - sheet entry point short-circuit

        func test_present_invalidClientToken_returnsFailedWithoutPresenting() async {
            // The integration test: bad token resolves .failed and never
            // touches the host VC. Use an unattached UIViewController as the
            // host — if `present(...)` actually attempted to show a modal on
            // it, UIKit would log a warning (no window) but more importantly
            // we'd see a non-`.failed` result if the short-circuit broke.
            let host = await UIViewController()
            let result = await MolliePaymentSheet.present(
                from: host,
                clientToken: "definitely-not-a-token",
                theme: MolliePaymentTheme()
            )
            guard case let .failed(error) = result else {
                XCTFail("Expected .failed for malformed token, got \(result)")
                return
            }
            guard case .invalidClientToken = error else {
                XCTFail("Expected .invalidClientToken, got \(error)")
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
        // The continuation behind `MolliePaymentSheet.present` is single-shot:
        // Swift's runtime traps if `resume(...)` is called twice. The submit
        // success and the swipe-to-dismiss can both land on the same runloop
        // tick, so the Resolver MUST drop everything after the first call.
        // These tests pin that invariant down at the Resolver level — the
        // PaymentSheetCoordinator-level guard in `resolve(_:)` is a second
        // line of defense and is exercised end-to-end in MR5/MR8.

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

        // MARK: - sessionFetched status mapping

        func test_statusString_knownStatus_returnsRawValue() throws {
            // Regression target: the .sessionFetched emit used to hardcode
            // "open" regardless of the real session status. The fix routes
            // SessionResponse.status through this helper so the timeline
            // reflects the actual observed value. Pin both branches of
            // ParsedEnum so a future change can't silently start emitting
            // "open" for every status again.
            let json = """
            {
              "sessionToken": "sess_abc",
              "status": "completed",
              "nextAction": {"actionType": "await"},
              "paymentAmount": {"amount": "10.00", "currency": "EUR"}
            }
            """
            let session = try MollieJSONDecoder().decode(SessionResponse.self, from: Data(json.utf8))
            XCTAssertEqual(PaymentSheetCoordinator.statusString(session.status), "completed")
        }

        func test_statusString_unknownStatus_returnsRawString() throws {
            // ParsedEnum.unknown surfaces server-side statuses the SDK
            // hasn't catalogued yet; we still want them visible on the
            // timeline rather than collapsed to "open".
            let json = """
            {
              "sessionToken": "sess_abc",
              "status": "some_future_status",
              "nextAction": {"actionType": "await"},
              "paymentAmount": {"amount": "10.00", "currency": "EUR"}
            }
            """
            let session = try MollieJSONDecoder().decode(SessionResponse.self, from: Data(json.utf8))
            XCTAssertEqual(PaymentSheetCoordinator.statusString(session.status), "some_future_status")
        }

        // MARK: - debug emit-site smoke

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
    }

#endif
