#if canImport(UIKit)
    import Foundation
    import XCTest
    @testable import MollieComponents
    @testable import MollieCore
    @testable import MolliePayments
    @testable import MolliePaymentsUI

    /// Embed-bridge-specific behaviour: single-shot resolve guard,
    /// invalid-snapshot short-circuit, cancel path. Parse/map/decode are
    /// already covered by `CardCheckoutRunnerTests` — the embed bridge
    /// delegates to the same statics, so we don't duplicate those
    /// assertions here.
    @MainActor
    final class EmbeddedFormBridgeTests: XCTestCase {
        // MARK: - Fixtures

        private func makeDecodedToken() throws -> ClientToken {
            let json = """
            {
              "sessionToken": "sess_embed",
              "secret": "shh",
              "availablePaymentMethods": ["creditcard"],
              "testmode": true,
              "profileToken": "pfl_embed",
              "merchantProfileName": "EmbedCo",
              "organizationCountryCode": "NL"
            }
            """
            let raw = try XCTUnwrap(json.data(using: .utf8)?.base64EncodedString())
            switch CardCheckoutRunner.decode(clientToken: raw) {
            case let .success(decoded): return decoded
            case let .failure(error): throw error
            }
        }

        private func makeBridge(
            onResult: @escaping (MolliePaymentResult) -> Void
        ) throws -> EmbeddedFormBridge {
            let token = try makeDecodedToken()
            return EmbeddedFormBridge(
                clientToken: token,
                rawClientToken: "irrelevant_for_these_tests",
                theme: MollieAppearance(),
                endpoints: .production,
                locale: .current,
                onResult: onResult
            )
        }

        // MARK: - Cancel path

        func test_handleCancel_firesOnResultOnceWithCancelled() throws {
            var results: [MolliePaymentResult] = []
            let bridge = try makeBridge { results.append($0) }
            bridge.handleCancel()
            XCTAssertEqual(results.count, 1)
            guard case .cancelled = results.first else {
                return XCTFail("Expected .cancelled, got \(String(describing: results.first))")
            }
        }

        func test_handleCancel_secondCallIsIgnored() throws {
            var results: [MolliePaymentResult] = []
            let bridge = try makeBridge { results.append($0) }
            bridge.handleCancel()
            bridge.handleCancel()
            XCTAssertEqual(results.count, 1, "Single-shot guard must collapse repeat cancels")
        }

        // MARK: - Invalid-snapshot short-circuit

        func test_handleSubmit_invalidSnapshot_firesFailedWithoutSubmitting() throws {
            var results: [MolliePaymentResult] = []
            let bridge = try makeBridge { results.append($0) }
            // Empty PAN trips CardFormValidator, which the bridge routes
            // through `CardCheckoutRunner.parse`; the embed path must
            // surface that as `.failed(.invalidConfiguration)` immediately
            // without scheduling a Task that touches the (non-existent)
            // network.
            let badSnapshot = CardFormSnapshot(
                cardholderName: "Ada Lovelace",
                cardNumber: "",
                expiry: "12/30",
                cvc: "123"
            )
            bridge.handleSubmit(snapshot: badSnapshot)
            XCTAssertEqual(results.count, 1)
            guard case let .failed(error) = results.first,
                  case .invalidConfiguration = error
            else {
                return XCTFail("Expected .failed(.invalidConfiguration), got \(String(describing: results.first))")
            }
        }

        func test_handleSubmit_thenCancel_onlyFirstResultDelivered() throws {
            var results: [MolliePaymentResult] = []
            let bridge = try makeBridge { results.append($0) }
            let badSnapshot = CardFormSnapshot(
                cardholderName: "",
                cardNumber: "",
                expiry: "",
                cvc: ""
            )
            bridge.handleSubmit(snapshot: badSnapshot)
            // Cancel after the natural terminal — single-shot guard must
            // swallow it. Without the guard the host would see a second
            // result land and might double-update its UI.
            bridge.handleCancel()
            XCTAssertEqual(results.count, 1, "Single-shot guard must hold across submit→cancel races")
        }

        // MARK: - Retryable soft decline

        /// A retryable soft decline has no shape in the deprecated
        /// `MolliePaymentResult` — unlike `resolve(_:)`, `resetForRetry()`
        /// must never invoke the merchant's `onResult` callback.
        func test_resetForRetry_doesNotFireOnResult() throws {
            var results: [MolliePaymentResult] = []
            let bridge = try makeBridge { results.append($0) }
            bridge.resetForRetry()
            XCTAssertTrue(results.isEmpty, "A retryable soft decline must not deliver a MolliePaymentResult")
        }

        /// The whole point of `resetForRetry()` vs. `resolve(_:)`: it must
        /// NOT trip the one-shot guard, so the bridge accepts a fresh
        /// attempt afterwards. Driving a real network retry isn't exercised
        /// here (no submit mocking in this suite — see the file doc
        /// comment); asserting that a subsequent terminal signal (cancel)
        /// still delivers is the observable proof the bridge stayed alive.
        func test_resetForRetry_bridgeStaysAliveForAnotherAttempt() throws {
            var results: [MolliePaymentResult] = []
            let bridge = try makeBridge { results.append($0) }
            bridge.resetForRetry()
            bridge.handleCancel()
            XCTAssertEqual(results.count, 1, "resetForRetry must not end the bridge's one-shot onResult delivery")
            guard case .cancelled = results.first else {
                return XCTFail("Expected .cancelled, got \(String(describing: results.first))")
            }
        }
    }
#endif
