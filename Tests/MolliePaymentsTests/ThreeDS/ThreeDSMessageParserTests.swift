#if canImport(WebKit)
    import XCTest
    @testable import MollieCore
    @testable import MolliePayments

    /// Exercises the package-internal `ThreeDSMessageHandler.parse` helper.
    /// `WKScriptMessage` has no public initialiser, so we test the pure
    /// parsing contract directly. The handler's main-frame guard and main-
    /// actor dispatch are integration concerns covered elsewhere.
    final class ThreeDSMessageHandlerTests: XCTestCase {
        // MARK: - complete

        func test_parse_completeWithZeroErrorCode_returnsAuthenticated() {
            let body: [String: Any] = ["sender": "mollie-interceptor", "type": "complete", "errorCode": 0]
            XCTAssertEqual(
                ThreeDSMessageHandler.parse(name: "mollieChallenge", body: body),
                .authenticated
            )
        }

        func test_parse_completeWithNonZeroErrorCode_returnsChallengeFailed() {
            let body: [String: Any] = ["sender": "mollie-interceptor", "type": "complete", "errorCode": 1001]
            XCTAssertEqual(
                ThreeDSMessageHandler.parse(name: "mollieChallenge", body: body),
                .failed(reason: .challengeFailed)
            )
        }

        func test_parse_completeWithMissingErrorCode_failsClosed() {
            // Fail-closed: a `complete` message without an explicit `errorCode`
            // must NOT be treated as authenticated. A compromised ACS could
            // otherwise omit the field to bypass auth.
            let body: [String: Any] = ["sender": "mollie-interceptor", "type": "complete"]
            XCTAssertEqual(
                ThreeDSMessageHandler.parse(name: "mollieChallenge", body: body),
                .failed(reason: .challengeFailed)
            )
        }

        func test_parse_completeWithNonIntErrorCode_failsClosed() {
            // Same rule for a wrong-typed errorCode — only explicit Int 0 authenticates.
            let body: [String: Any] = ["sender": "mollie-interceptor", "type": "complete", "errorCode": "0"]
            XCTAssertEqual(
                ThreeDSMessageHandler.parse(name: "mollieChallenge", body: body),
                .failed(reason: .challengeFailed)
            )
        }

        func test_parse_completeWithExplicitZeroErrorCode_authenticates() {
            // Positive control: errorCode=0 *must* be present and an Int for auth.
            let body: [String: Any] = ["sender": "mollie-interceptor", "type": "complete", "errorCode": 0]
            XCTAssertEqual(
                ThreeDSMessageHandler.parse(name: "mollieChallenge", body: body),
                .authenticated
            )
        }

        // MARK: - error

        func test_parse_errorWithCode_returnsFailedSdkErrorWithCode() {
            let body: [String: Any] = ["sender": "mollie-interceptor", "type": "error", "errorCode": 500]
            XCTAssertEqual(
                ThreeDSMessageHandler.parse(name: "mollieChallenge", body: body),
                .failed(reason: .sdkError(message: "3DS error 500"))
            )
        }

        // MARK: - canceled

        func test_parse_canceled_returnsCancelled() {
            let body: [String: Any] = ["sender": "mollie-interceptor", "type": "canceled"]
            XCTAssertEqual(
                ThreeDSMessageHandler.parse(name: "mollieChallenge", body: body),
                .cancelled
            )
        }

        // MARK: - no-op cases (return nil)

        func test_parse_unknownType_returnsNil() {
            let body: [String: Any] = ["sender": "mollie-interceptor", "type": "challenge"]
            XCTAssertNil(ThreeDSMessageHandler.parse(name: "mollieChallenge", body: body))
        }

        func test_parse_wrongHandlerName_returnsNil() {
            let body: [String: Any] = ["sender": "mollie-interceptor", "type": "complete", "errorCode": 0]
            XCTAssertNil(ThreeDSMessageHandler.parse(name: "somethingElse", body: body))
        }

        func test_parse_missingSender_returnsNil() {
            let body: [String: Any] = ["type": "complete", "errorCode": 0]
            XCTAssertNil(ThreeDSMessageHandler.parse(name: "mollieChallenge", body: body))
        }

        func test_parse_wrongSender_returnsNil() {
            let body: [String: Any] = ["sender": "evil", "type": "complete", "errorCode": 0]
            XCTAssertNil(ThreeDSMessageHandler.parse(name: "mollieChallenge", body: body))
        }

        func test_parse_bodyNotADict_returnsNil() {
            XCTAssertNil(ThreeDSMessageHandler.parse(name: "mollieChallenge", body: "not a dict"))
        }

        func test_parse_validSenderAndNameButMissingType_returnsNil() {
            let body: [String: Any] = ["sender": "mollie-interceptor", "errorCode": 0]
            XCTAssertNil(ThreeDSMessageHandler.parse(name: "mollieChallenge", body: body))
        }

        // MARK: - parseBridgeEvent (non-terminal channel)

        func test_parseBridgeEvent_challenge_returnsChallengeEscalation() {
            // A `type:"challenge"` message signals interactive UI is about to
            // show. It must surface as the non-terminal escalation event and
            // NEVER collapse into a terminal ThreeDSResult.
            let body: [String: Any] = ["sender": "mollie-interceptor", "type": "challenge"]
            XCTAssertEqual(
                ThreeDSMessageHandler.parseBridgeEvent(name: "mollieChallenge", body: body),
                .challengeEscalation
            )
        }

        func test_parseBridgeEvent_complete_returnsResultAuthenticated() {
            // Terminal types must delegate to the existing fail-closed parse
            // and be wrapped in `.result`, not `.challengeEscalation`.
            let body: [String: Any] = ["sender": "mollie-interceptor", "type": "complete", "errorCode": 0]
            XCTAssertEqual(
                ThreeDSMessageHandler.parseBridgeEvent(name: "mollieChallenge", body: body),
                .result(.authenticated)
            )
        }

        func test_parseBridgeEvent_completeMissingErrorCode_resultFailsClosed() {
            // The fail-closed errorCode contract must hold through the bridge
            // channel too: a `complete` without explicit Int 0 is a failure.
            let body: [String: Any] = ["sender": "mollie-interceptor", "type": "complete"]
            XCTAssertEqual(
                ThreeDSMessageHandler.parseBridgeEvent(name: "mollieChallenge", body: body),
                .result(.failed(reason: .challengeFailed))
            )
        }

        func test_parseBridgeEvent_error_returnsResultFailedSdkError() {
            let body: [String: Any] = ["sender": "mollie-interceptor", "type": "error", "errorCode": 500]
            XCTAssertEqual(
                ThreeDSMessageHandler.parseBridgeEvent(name: "mollieChallenge", body: body),
                .result(.failed(reason: .sdkError(message: "3DS error 500")))
            )
        }

        func test_parseBridgeEvent_canceled_returnsResultCancelled() {
            let body: [String: Any] = ["sender": "mollie-interceptor", "type": "canceled"]
            XCTAssertEqual(
                ThreeDSMessageHandler.parseBridgeEvent(name: "mollieChallenge", body: body),
                .result(.cancelled)
            )
        }

        func test_parseBridgeEvent_wrongSender_returnsNil() {
            // The interceptor-only sender guard must apply to the bridge channel
            // too, so a spoofed challenge cannot force the modal to present.
            let body: [String: Any] = ["sender": "evil", "type": "challenge"]
            XCTAssertNil(ThreeDSMessageHandler.parseBridgeEvent(name: "mollieChallenge", body: body))
        }

        func test_parseBridgeEvent_wrongHandlerName_returnsNil() {
            let body: [String: Any] = ["sender": "mollie-interceptor", "type": "challenge"]
            XCTAssertNil(ThreeDSMessageHandler.parseBridgeEvent(name: "somethingElse", body: body))
        }

        func test_parseBridgeEvent_unknownType_returnsNil() {
            let body: [String: Any] = ["sender": "mollie-interceptor", "type": "bogus"]
            XCTAssertNil(ThreeDSMessageHandler.parseBridgeEvent(name: "mollieChallenge", body: body))
        }

        func test_parseBridgeEvent_bodyNotADict_returnsNil() {
            XCTAssertNil(ThreeDSMessageHandler.parseBridgeEvent(name: "mollieChallenge", body: "not a dict"))
        }

        // MARK: - DevTools summary redaction

        func test_makeSummary_withType_returnsTypeString() {
            let body: [String: Any] = ["sender": "mollie-interceptor", "type": "complete"]
            XCTAssertEqual(ThreeDSMessageHandler.makeSummary(body), "type=complete")
        }

        func test_makeSummary_withTypeAndErrorCode_returnsBoth() {
            let body: [String: Any] = ["sender": "mollie-interceptor", "type": "error", "errorCode": 1001]
            XCTAssertEqual(ThreeDSMessageHandler.makeSummary(body), "type=error errorCode=1001")
        }

        func test_makeSummary_omitsAllOtherBodyFields() {
            // PCI safety: even if the ACS page ever attached pan/cvv-shaped
            // fields, the summary must still surface only type+errorCode.
            let body: [String: Any] = [
                "sender": "mollie-interceptor",
                "type": "complete",
                "pan": "4242424242424242",
                "cvv": "123",
                "cardNumber": "4242424242424242",
            ]
            let summary = ThreeDSMessageHandler.makeSummary(body)
            XCTAssertEqual(summary, "type=complete")
            XCTAssertFalse(summary.contains("4242"))
            XCTAssertFalse(summary.contains("cvv"))
            XCTAssertFalse(summary.contains("123"))
        }

        func test_makeSummary_nonDictBody_returnsUnknown() {
            XCTAssertEqual(ThreeDSMessageHandler.makeSummary("not a dict"), "type=unknown")
        }
    }
#endif
