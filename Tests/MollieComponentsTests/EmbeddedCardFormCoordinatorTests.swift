#if canImport(UIKit)
    import Foundation
    import XCTest
    @testable import MollieComponents
    @testable import MollieCore
    @testable import MolliePayments
    @testable import MolliePaymentsUI

    /// Embed-coordinator-specific behaviour: single-shot resolve guard,
    /// invalid-snapshot short-circuit, cancel path. Parse/map/decode are
    /// already covered by `PaymentSheetCoordinatorTests` — the embed
    /// coordinator delegates to the same statics, so we don't duplicate
    /// those assertions here.
    @MainActor
    final class EmbeddedCardFormCoordinatorTests: XCTestCase {
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
            switch PaymentSheetCoordinator.decode(clientToken: raw) {
            case let .success(decoded): return decoded
            case let .failure(error): throw error
            }
        }

        private func makeCoordinator(
            onResult: @escaping (MolliePaymentResult) -> Void
        ) throws -> EmbeddedCardFormCoordinator {
            let token = try makeDecodedToken()
            return EmbeddedCardFormCoordinator(
                clientToken: token,
                rawClientToken: "irrelevant_for_these_tests",
                theme: MolliePaymentTheme(),
                endpoints: .production,
                onResult: onResult
            )
        }

        // MARK: - Cancel path

        func test_handleCancel_firesOnResultOnceWithCancelled() throws {
            var results: [MolliePaymentResult] = []
            let coordinator = try makeCoordinator { results.append($0) }
            coordinator.handleCancel()
            XCTAssertEqual(results.count, 1)
            guard case .cancelled = results.first else {
                return XCTFail("Expected .cancelled, got \(String(describing: results.first))")
            }
        }

        func test_handleCancel_secondCallIsIgnored() throws {
            var results: [MolliePaymentResult] = []
            let coordinator = try makeCoordinator { results.append($0) }
            coordinator.handleCancel()
            coordinator.handleCancel()
            XCTAssertEqual(results.count, 1, "Single-shot guard must collapse repeat cancels")
        }

        // MARK: - Invalid-snapshot short-circuit

        func test_handleSubmit_invalidSnapshot_firesFailedWithoutSubmitting() throws {
            var results: [MolliePaymentResult] = []
            let coordinator = try makeCoordinator { results.append($0) }
            // Empty PAN trips CardFormValidator, which the coordinator
            // routes through `PaymentSheetCoordinator.parse`; the embed
            // path must surface that as `.failed(.invalidConfiguration)`
            // immediately without scheduling a Task that touches the
            // (non-existent) network.
            let badSnapshot = CardFormSnapshot(
                cardholderName: "Ada Lovelace",
                cardNumber: "",
                expiry: "12/30",
                cvc: "123"
            )
            coordinator.handleSubmit(snapshot: badSnapshot)
            XCTAssertEqual(results.count, 1)
            guard case let .failed(error) = results.first,
                  case .invalidConfiguration = error
            else {
                return XCTFail("Expected .failed(.invalidConfiguration), got \(String(describing: results.first))")
            }
        }

        func test_handleSubmit_thenCancel_onlyFirstResultDelivered() throws {
            var results: [MolliePaymentResult] = []
            let coordinator = try makeCoordinator { results.append($0) }
            let badSnapshot = CardFormSnapshot(
                cardholderName: "",
                cardNumber: "",
                expiry: "",
                cvc: ""
            )
            coordinator.handleSubmit(snapshot: badSnapshot)
            // Cancel after the natural terminal — single-shot guard must
            // swallow it. Without the guard the host would see a second
            // result land and might double-update its UI.
            coordinator.handleCancel()
            XCTAssertEqual(results.count, 1, "Single-shot guard must hold across submit→cancel races")
        }
    }
#endif
