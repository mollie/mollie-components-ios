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
