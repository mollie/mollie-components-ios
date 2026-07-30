#if canImport(UIKit)
    import Foundation
    import XCTest
    @testable import MollieComponents
    @testable import MollieCore
    @testable import MolliePayments
    @testable import MolliePaymentsUI

    /// Shared-logic verification for `CardCheckoutRunner`: clientToken decode
    /// error paths short-circuit before any UI presents, raw form input is
    /// parsed into a typed submission shape, and the engine's
    /// `CardPaymentResult` maps cleanly onto the merchant-facing
    /// `MolliePaymentResult`. Both `MollieCheckout.presentCard(from:)`
    /// (modal) and `MollieCardComponent` (embed) delegate to these same
    /// statics, so this suite covers both call sites at once. End-to-end
    /// flows (real submit + 3DS) are covered by `CardCheckoutModalCoordinatorTests`
    /// — they require a running form behaviour layer that lands there.
    @MainActor
    final class CardCheckoutRunnerTests: XCTestCase {
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

            switch CardCheckoutRunner.decode(clientToken: token) {
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
            // .invalidClientToken so the caller can return .failed BEFORE any
            // UI presents — not a generic .unknown that the merchant can't
            // pattern-match.
            switch CardCheckoutRunner.decode(clientToken: "not-valid-base64-@@@") {
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
            switch CardCheckoutRunner.decode(clientToken: "") {
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
            switch CardCheckoutRunner.decode(clientToken: token) {
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
            switch CardCheckoutRunner.decode(clientToken: token) {
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
            switch CardCheckoutRunner.parse(snapshot: snapshot) {
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
            switch CardCheckoutRunner.parse(snapshot: snapshot) {
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
            switch CardCheckoutRunner.parse(snapshot: snapshot) {
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
            switch CardCheckoutRunner.parse(snapshot: snapshot) {
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
            let mapped = CardCheckoutRunner.map(cardResult: .completed(session))
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
            let mapped = CardCheckoutRunner.map(
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
            let mapped = CardCheckoutRunner.map(cardResult: .cancelled)
            guard case .cancelled = mapped else {
                XCTFail("Expected .cancelled, got \(mapped)")
                return
            }
        }

        /// `mapFinalEvent` now produces the real, non-terminal
        /// `.attemptFailed` for this `CardPaymentResult`, but the deprecated
        /// `MolliePaymentResult` this function returns has no case for it —
        /// `MolliePaymentResult.init(checkoutEvent:)` folds it into
        /// `.failed`. Pins that the merchant-facing `onResult`/`presentCard`
        /// contract stays exactly as it was before this task; only
        /// `MollieCheckout.events`/`eventsPublisher` gain the richer signal.
        func test_map_attemptFailed_foldsToFailedSessionFailed() {
            let details = ProblemDetails(title: "declined", detail: "insufficient funds")
            let mapped = CardCheckoutRunner.map(cardResult: .attemptFailed(details))
            guard case let .failed(error) = mapped,
                  case let .sessionFailed(problemDetails) = error
            else {
                XCTFail("Expected .failed(.sessionFailed), got \(mapped)")
                return
            }
            XCTAssertEqual(problemDetails?.title, "declined")
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
            XCTAssertEqual(CardCheckoutRunner.statusString(session.status), "completed")
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
            XCTAssertEqual(CardCheckoutRunner.statusString(session.status), "some_future_status")
        }

        // MARK: - channels-client DI gating

        func test_makeChannelsClient_pusherEnabled_returnsPusherClient() throws {
            // The feature flag plus a `pusherConfiguration` block are what wire
            // the live `PusherChannelsClient` at the DI site: the
            // backend is the single source of truth for key/cluster/channel/
            // event now, so the enabled case must carry a full config. This
            // encodes the intent — a future refactor that drops the gate would
            // silently leave every session poll-only.
            let json = """
            {
              "sessionToken": "sess_abc",
              "secret": "shh",
              "availablePaymentMethods": ["creditcard"],
              "testmode": true,
              "profileToken": "pfl_xyz",
              "_enabledFeatures": ["session_pusher_enabled"],
              "pusherConfiguration": {
                "key": "k",
                "cluster": "eu",
                "channel": "px_sessions_app_session_sess_abc",
                "event": "session_changed"
              }
            }
            """
            let token = try ClientToken.decode(from: XCTUnwrap(json.data(using: .utf8)?.base64EncodedString()))
            XCTAssertTrue(token.isPusherEnabled)

            let client = CardCheckoutRunner.makeChannelsClient(clientToken: token)
            XCTAssertTrue(client is PusherChannelsClient)
        }

        func test_makeChannelsClient_pusherDisabled_returnsNoOpClient() throws {
            // No flag → no socket: the SDK must stay poll-only so a merchant who
            // hasn't been opted in never opens a Pusher connection.
            let json = """
            {
              "sessionToken": "sess_abc",
              "secret": "shh",
              "availablePaymentMethods": ["creditcard"],
              "testmode": true,
              "profileToken": "pfl_xyz"
            }
            """
            let token = try ClientToken.decode(from: XCTUnwrap(json.data(using: .utf8)?.base64EncodedString()))
            XCTAssertFalse(token.isPusherEnabled)

            let client = CardCheckoutRunner.makeChannelsClient(clientToken: token)
            XCTAssertTrue(client is NoOpChannelsClient)
        }

        func test_makeChannelsClient_pusherEnabledButNoConfig_returnsNoOpClient() throws {
            // Fail-safe case: the feature flag is on but the backend didn't
            // (yet) attach a `pusherConfiguration` block. The SDK has no
            // hardcoded fallback key anymore, so it must fail safe to polling
            // rather than guess connection parameters.
            let json = """
            {
              "sessionToken": "sess_abc",
              "secret": "shh",
              "availablePaymentMethods": ["creditcard"],
              "testmode": true,
              "profileToken": "pfl_xyz",
              "_enabledFeatures": ["session_pusher_enabled"]
            }
            """
            let token = try ClientToken.decode(from: XCTUnwrap(json.data(using: .utf8)?.base64EncodedString()))
            XCTAssertTrue(token.isPusherEnabled)
            XCTAssertNil(token.pusherConfiguration)

            let client = CardCheckoutRunner.makeChannelsClient(clientToken: token)
            XCTAssertTrue(client is NoOpChannelsClient)
        }

        func test_makeChannelsClient_pusherEnabledButEmptyConfigField_returnsNoOpClient() throws {
            // Fail-safe case: a `pusherConfiguration` block is present but an
            // empty required field (here: `channel`) slipped through. Opening a
            // subscription with an empty channel would be live-but-broken, so the
            // SDK must stay poll-only instead.
            let json = """
            {
              "sessionToken": "sess_abc",
              "secret": "shh",
              "availablePaymentMethods": ["creditcard"],
              "testmode": true,
              "profileToken": "pfl_xyz",
              "_enabledFeatures": ["session_pusher_enabled"],
              "pusherConfiguration": {
                "key": "k",
                "cluster": "eu",
                "channel": "",
                "event": "session_changed"
              }
            }
            """
            let token = try ClientToken.decode(from: XCTUnwrap(json.data(using: .utf8)?.base64EncodedString()))
            XCTAssertNotNil(token.pusherConfiguration)

            let client = CardCheckoutRunner.makeChannelsClient(clientToken: token)
            XCTAssertTrue(client is NoOpChannelsClient)
        }
    }
#endif
