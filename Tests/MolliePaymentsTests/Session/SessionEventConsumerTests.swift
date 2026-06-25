import XCTest
@testable import MollieCore
@testable import MolliePayments

final class SessionEventConsumerTests: XCTestCase {
    // MARK: - Helpers

    private func decodeSession(_ json: String) throws -> SessionResponse {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(SessionResponse.self, from: Data(json.utf8))
    }

    private func makeConsumer(
        mock: MockHTTPClient,
        intervals: [TimeInterval] = [0.01],
        totalBudget: TimeInterval = 1.0
    ) -> SessionEventConsumer {
        let poller = SessionPoller(
            httpClient: mock,
            sessionToken: "sess_abc123",
            schedule: PollingSchedule(intervals: intervals, totalBudget: totalBudget)
        )
        return SessionEventConsumer(
            channelsClient: NoOpChannelsClient(),
            sessionPoller: poller
        )
    }

    private let openSessionJSON = """
    {
        "session_token": "sess_abc123",
        "status": "open",
        "next_action": { "action_type": "await" },
        "payment_amount": { "amount": "10.00", "currency": "EUR" }
    }
    """

    private let completedSessionJSON = """
    {
        "session_token": "sess_abc123",
        "status": "completed",
        "next_action": { "action_type": "none" },
        "payment_amount": { "amount": "10.00", "currency": "EUR" }
    }
    """

    private let threeDSChallengeJSON = """
    {
        "session_token": "sess_abc123",
        "status": "open",
        "next_action": {
            "action_type": "threeDsChallenge",
            "params": { "challenge_url": "https://3ds.example.com/challenge" }
        },
        "payment_amount": { "amount": "10.00", "currency": "EUR" }
    }
    """

    private let threeDSMissingURLJSON = """
    {
        "session_token": "sess_abc123",
        "status": "open",
        "next_action": {
            "action_type": "threeDsChallenge"
        },
        "payment_amount": { "amount": "10.00", "currency": "EUR" }
    }
    """

    private let readyToProcessJSON = """
    {
        "session_token": "sess_abc123",
        "status": "open",
        "next_action": {
            "action_type": "readyToProcess",
            "params": { "pspToken": "psp_test" }
        },
        "payment_amount": { "amount": "10.00", "currency": "EUR" }
    }
    """

    private let redirectJSON = """
    {
        "session_token": "sess_abc123",
        "status": "open",
        "next_action": {
            "action_type": "redirect",
            "params": { "url": "https://merchant.example.com/return?id=abc" }
        },
        "payment_amount": { "amount": "10.00", "currency": "EUR" },
        "redirect_url": "https://merchant.example.com/return?id=abc"
    }
    """

    // MARK: - Tests

    func test_observe_completedSession_emitsCompletedThenFinishes() async throws {
        let mock = MockHTTPClient()
        let completed = try decodeSession(completedSessionJSON)
        mock.enqueue(completed)

        let consumer = makeConsumer(mock: mock)
        var events: [ChannelEvent] = []
        for try await event in consumer.observe(sessionToken: "sess_abc123") {
            events.append(event)
        }

        XCTAssertEqual(events.count, 1)
        guard case let .sessionCompleted(response) = events[0] else {
            return XCTFail("Expected .sessionCompleted, got \(events[0])")
        }
        XCTAssertEqual(response.sessionToken, "sess_abc123")
    }

    func test_observe_openThenCompleted_emitsUpdateThenCompleted() async throws {
        let mock = MockHTTPClient()
        let open = try decodeSession(openSessionJSON)
        let completed = try decodeSession(completedSessionJSON)
        mock.enqueue(open)
        mock.enqueue(completed)

        let consumer = makeConsumer(mock: mock)
        var events: [ChannelEvent] = []
        for try await event in consumer.observe(sessionToken: "sess_abc123") {
            events.append(event)
        }

        XCTAssertEqual(events.count, 2)
        guard case .sessionUpdated = events[0] else {
            return XCTFail("Expected .sessionUpdated, got \(events[0])")
        }
        guard case .sessionCompleted = events[1] else {
            return XCTFail("Expected .sessionCompleted, got \(events[1])")
        }
    }

    func test_observe_threeDSAction_emitsChallengeReady() async throws {
        let mock = MockHTTPClient()
        let challenge = try decodeSession(threeDSChallengeJSON)
        let completed = try decodeSession(completedSessionJSON)
        mock.enqueue(challenge)
        mock.enqueue(completed)

        let consumer = makeConsumer(mock: mock)
        var events: [ChannelEvent] = []
        for try await event in consumer.observe(sessionToken: "sess_abc123") {
            events.append(event)
        }

        // Action events (.threeDSChallengeReady) are preceded by a synthetic
        // .sessionUpdated so the coordinator's `lastSession` is populated with
        // the response carrying `redirectUrl` BEFORE the WebView presenter is
        // invoked. Without that, the navigation policy's merchant-return arm
        // has nothing to match against and the WebView happily renders the
        // merchant's redirect page when the issuer ACS bounces back to it.
        XCTAssertEqual(events.count, 3)
        guard case .sessionUpdated = events[0] else {
            return XCTFail("Expected .sessionUpdated before action event, got \(events[0])")
        }
        guard case let .threeDSChallengeReady(url) = events[1] else {
            return XCTFail("Expected .threeDSChallengeReady, got \(events[1])")
        }
        XCTAssertEqual(url, URL(string: "https://3ds.example.com/challenge"))
        guard case .sessionCompleted = events[2] else {
            return XCTFail("Expected .sessionCompleted, got \(events[2])")
        }
    }

    func test_observe_threeDSAction_missingURL_yieldsUpdateInstead() async throws {
        let mock = MockHTTPClient()
        let missing = try decodeSession(threeDSMissingURLJSON)
        let completed = try decodeSession(completedSessionJSON)
        mock.enqueue(missing)
        mock.enqueue(completed)

        let consumer = makeConsumer(mock: mock)
        var events: [ChannelEvent] = []
        for try await event in consumer.observe(sessionToken: "sess_abc123") {
            events.append(event)
        }

        XCTAssertEqual(events.count, 2)
        guard case .sessionUpdated = events[0] else {
            return XCTFail("Expected .sessionUpdated when challengeUrl is missing, got \(events[0])")
        }
        guard case .sessionCompleted = events[1] else {
            return XCTFail("Expected .sessionCompleted, got \(events[1])")
        }
    }

    // FIX #11: validate URLs at the mapper. A hostile server response with
    // `javascript:` (or any non-https / loopback / RFC1918 host) must NOT
    // surface a `.threeDSChallengeReady` event — surface `.sessionFailed`
    // with an invalid-configuration ProblemDetails instead so the sheet is
    // never presented.
    func test_observe_threeDSChallengeURL_javascriptScheme_yieldsSessionFailed() async throws {
        let json = """
        {
            "session_token": "sess_abc123",
            "status": "open",
            "next_action": {
                "action_type": "threeDsChallenge",
                "params": { "challenge_url": "javascript:alert(1)" }
            },
            "payment_amount": { "amount": "10.00", "currency": "EUR" }
        }
        """
        let mock = MockHTTPClient()
        try mock.enqueue(decodeSession(json))

        let consumer = makeConsumer(mock: mock)
        var events: [ChannelEvent] = []
        do {
            for try await event in consumer.observe(sessionToken: "sess_abc123") {
                events.append(event)
            }
        } catch {}

        XCTAssertEqual(events.count, 1)
        guard case let .sessionFailed(details) = events[0] else {
            return XCTFail("Expected .sessionFailed for javascript: URL, got \(events[0])")
        }
        XCTAssertEqual(details?.title, "invalid_configuration")
        // Critically, no .threeDSChallengeReady — the sheet must NEVER be
        // presented with an unsafe URL.
        for event in events {
            if case .threeDSChallengeReady = event {
                XCTFail("Must not yield .threeDSChallengeReady for unsafe URL")
            }
        }
    }

    func test_observe_redirectURL_loopbackHost_yieldsSessionFailed() async throws {
        let json = """
        {
            "session_token": "sess_abc123",
            "status": "open",
            "next_action": {
                "action_type": "redirect",
                "params": { "url": "https://127.0.0.1/exfil" }
            },
            "payment_amount": { "amount": "10.00", "currency": "EUR" }
        }
        """
        let mock = MockHTTPClient()
        try mock.enqueue(decodeSession(json))

        let consumer = makeConsumer(mock: mock)
        var events: [ChannelEvent] = []
        do {
            for try await event in consumer.observe(sessionToken: "sess_abc123") {
                events.append(event)
            }
        } catch {}

        XCTAssertEqual(events.count, 1)
        guard case let .sessionFailed(details) = events[0] else {
            return XCTFail("Expected .sessionFailed for loopback redirect, got \(events[0])")
        }
        XCTAssertEqual(details?.title, "invalid_configuration")
    }

    func test_observe_pollerTimeout_throws() async throws {
        let mock = MockHTTPClient()
        let open = try decodeSession(openSessionJSON)
        mock.enqueueRepeating(open)

        let consumer = makeConsumer(
            mock: mock,
            intervals: [0.01, 0.01, 0.01],
            totalBudget: 0.05
        )

        do {
            for try await _ in consumer.observe(sessionToken: "sess_abc123") {
                // drain
            }
            XCTFail("Expected MollieError.timeout, stream finished without error")
        } catch let MollieError.timeout(operation) {
            XCTAssertEqual(operation, "session-polling")
        } catch {
            XCTFail("Expected MollieError.timeout, got \(error)")
        }
    }

    func test_observe_readyToProcess_yieldsSessionUpdated_notTerminal() async throws {
        // Regression: previously map() treated readyToProcess as terminal, which
        // short-circuited the coordinator before 3DS or before the acquirer
        // finished. Per the server contract, the client does nothing on
        // readyToProcess — it just keeps polling while the server auto-processes.
        let mock = MockHTTPClient()
        let ready = try decodeSession(readyToProcessJSON)
        let completed = try decodeSession(completedSessionJSON)
        mock.enqueue(ready)
        mock.enqueue(completed)

        let consumer = makeConsumer(mock: mock)
        var events: [ChannelEvent] = []
        for try await event in consumer.observe(sessionToken: "sess_abc123") {
            events.append(event)
        }

        XCTAssertEqual(events.count, 2)
        guard case .sessionUpdated = events[0] else {
            return XCTFail("Expected .sessionUpdated for readyToProcess, got \(events[0])")
        }
        guard case .sessionCompleted = events[1] else {
            return XCTFail("Expected .sessionCompleted, got \(events[1])")
        }
    }

    func test_observe_redirectActionType_yieldsRedirectRequired_notTerminal() async throws {
        // Server emits nextAction.actionType=redirect with a hosted-page URL
        // (Mollie's prepare-authentication / final-screen). The SDK must NOT
        // treat this as a terminal success — earlier code mapped it to
        // .sessionCompleted, which caused the UI to claim "Payment completed"
        // on payments that were still open at the card processor. The correct
        // mapping is .redirectRequired (non-terminal) so the coordinator can
        // present the URL and resume polling until status=completed.
        let mock = MockHTTPClient()
        try mock.enqueue(decodeSession(redirectJSON))
        try mock.enqueue(decodeSession(completedSessionJSON))

        let consumer = makeConsumer(mock: mock)
        var events: [ChannelEvent] = []
        for try await event in consumer.observe(sessionToken: "sess_abc123") {
            events.append(event)
        }

        // Action events (.redirectRequired) are preceded by a synthetic
        // .sessionUpdated so the coordinator's `lastSession` carries the
        // merchant's `redirectUrl` before the WebView presenter is invoked.
        // See yieldEvents(for:into:) in SessionEventConsumer.
        XCTAssertEqual(events.count, 3)
        guard case let .sessionUpdated(updateSession) = events[0] else {
            return XCTFail("Expected .sessionUpdated before action event, got \(events[0])")
        }
        XCTAssertEqual(updateSession.redirectUrl, "https://merchant.example.com/return?id=abc")
        guard case let .redirectRequired(url) = events[1] else {
            return XCTFail("Expected .redirectRequired as second event, got \(events[1])")
        }
        XCTAssertEqual(url.absoluteString, "https://merchant.example.com/return?id=abc")
        guard case .sessionCompleted = events[2] else {
            return XCTFail("Expected .sessionCompleted as third event, got \(events[2])")
        }
    }

    func test_observe_pollerHttpError_propagates() async throws {
        let mock = MockHTTPClient()
        mock.enqueue(error: MollieError.api(.unauthorized))

        let consumer = makeConsumer(mock: mock)

        do {
            for try await _ in consumer.observe(sessionToken: "sess_abc123") {
                // drain
            }
            XCTFail("Expected MollieError.api(.unauthorized)")
        } catch let MollieError.api(apiError) {
            XCTAssertEqual(apiError, .unauthorized)
        } catch {
            XCTFail("Expected MollieError.api(.unauthorized), got \(error)")
        }
    }

    func test_observe_errorActionType_yieldsSessionFailed() async throws {
        let errorJSON = """
        {
            "session_token": "sess_abc123",
            "status": "open",
            "next_action": { "action_type": "error" },
            "payment_amount": { "amount": "10.00", "currency": "EUR" }
        }
        """
        let mock = MockHTTPClient()
        let errorResponse = try decodeSession(errorJSON)
        mock.enqueue(errorResponse)

        let consumer = makeConsumer(mock: mock)
        var events: [ChannelEvent] = []
        do {
            for try await event in consumer.observe(sessionToken: "sess_abc123") {
                events.append(event)
            }
        } catch {}

        XCTAssertEqual(events.count, 1)
        guard case let .sessionFailed(details) = events[0] else {
            return XCTFail("Expected .sessionFailed for error actionType, got \(events[0])")
        }
        // Synthesizer always populates a non-nil ProblemDetails (was nil
        // pre-fix). Empty params → detail falls back to "unknown".
        XCTAssertNotNil(details)
    }

    func test_observe_threeDSChallengeURL_snakeCaseKey_emitsChallengeReady() async throws {
        // Regression: wire key is "challenge_url" (snake_case); dictionary lookup is literal.
        // A camelCase key ("challengeUrl") would silently return nil and fall back to .sessionUpdated.
        let snakeCaseJSON = """
        {
            "session_token": "sess_abc123",
            "status": "open",
            "next_action": {
                "action_type": "threeDsChallenge",
                "params": { "challenge_url": "https://3ds.example.com/acs" }
            },
            "payment_amount": { "amount": "10.00", "currency": "EUR" }
        }
        """
        let camelCaseJSON = """
        {
            "session_token": "sess_abc123",
            "status": "open",
            "next_action": {
                "action_type": "threeDsChallenge",
                "params": { "challengeUrl": "https://3ds.example.com/acs" }
            },
            "payment_amount": { "amount": "10.00", "currency": "EUR" }
        }
        """
        let mock = MockHTTPClient()
        let snakeResponse = try decodeSession(snakeCaseJSON)
        let camelResponse = try decodeSession(camelCaseJSON)
        let completed = try decodeSession(completedSessionJSON)
        mock.enqueue(snakeResponse) // snake_case → should emit .threeDSChallengeReady
        mock.enqueue(camelResponse) // camelCase → should emit .sessionUpdated (key mismatch)
        mock.enqueue(completed)

        let consumer = makeConsumer(mock: mock)
        var events: [ChannelEvent] = []
        for try await event in consumer.observe(sessionToken: "sess_abc123") {
            events.append(event)
        }

        // Action events (.threeDSChallengeReady) are preceded by a synthetic
        // .sessionUpdated; see yieldEvents(for:into:) in SessionEventConsumer.
        XCTAssertEqual(events.count, 4)
        guard case .sessionUpdated = events[0] else {
            return XCTFail("Expected .sessionUpdated before action event, got \(events[0])")
        }
        guard case let .threeDSChallengeReady(url) = events[1] else {
            return XCTFail("Expected .threeDSChallengeReady for snake_case key, got \(events[1])")
        }
        XCTAssertEqual(url.absoluteString, "https://3ds.example.com/acs")
        guard case .sessionUpdated = events[2] else {
            return XCTFail("Expected .sessionUpdated for camelCase key (mismatch), got \(events[2])")
        }
        guard case .sessionCompleted = events[3] else {
            return XCTFail("Expected .sessionCompleted, got \(events[3])")
        }
    }

    // MARK: - observeAttempt(sessionToken:)

    private func makeAttemptConsumer(
        mock: MockHTTPClient,
        checkoutAttemptToken: String = "cat_abc",
        intervals: [TimeInterval] = [0.01],
        totalBudget: TimeInterval = 1.0
    ) -> SessionEventConsumer {
        let poller = SessionPoller(
            httpClient: mock,
            sessionToken: "sess_abc123",
            checkoutAttemptToken: checkoutAttemptToken,
            schedule: PollingSchedule(intervals: intervals, totalBudget: totalBudget)
        )
        return SessionEventConsumer(
            channelsClient: NoOpChannelsClient(),
            sessionPoller: poller
        )
    }

    private func makeAttemptMap(token: String, json: String) throws -> CheckoutAttemptsStateMap {
        let mapJSON = #"{ "\#(token)": \#(json) }"#
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(CheckoutAttemptsStateMap.self, from: Data(mapJSON.utf8))
    }

    func test_observeAttempt_completed_emitsCompleted() async throws {
        let mock = MockHTTPClient()
        let map = try makeAttemptMap(token: "cat_abc", json: completedSessionJSON)
        mock.enqueue(map)

        let consumer = makeAttemptConsumer(mock: mock)
        var events: [ChannelEvent] = []
        for try await event in consumer.observeAttempt(sessionToken: "sess_abc123") {
            events.append(event)
        }

        XCTAssertEqual(events.count, 1)
        guard case .sessionCompleted = events[0] else {
            return XCTFail("Expected .sessionCompleted, got \(events[0])")
        }
    }

    func test_observeAttempt_threeDSChallenge_emitsChallengeReady() async throws {
        let mock = MockHTTPClient()
        let challengeMap = try makeAttemptMap(token: "cat_abc", json: threeDSChallengeJSON)
        let completedMap = try makeAttemptMap(token: "cat_abc", json: completedSessionJSON)
        mock.enqueue(challengeMap)
        mock.enqueue(completedMap)

        let consumer = makeAttemptConsumer(mock: mock)
        var events: [ChannelEvent] = []
        for try await event in consumer.observeAttempt(sessionToken: "sess_abc123") {
            events.append(event)
        }

        // Action events are preceded by a synthetic .sessionUpdated; see
        // yieldEvents(for:into:) in SessionEventConsumer.
        XCTAssertEqual(events.count, 3)
        guard case .sessionUpdated = events[0] else {
            return XCTFail("Expected .sessionUpdated before action event, got \(events[0])")
        }
        guard case let .threeDSChallengeReady(url) = events[1] else {
            return XCTFail("Expected .threeDSChallengeReady, got \(events[1])")
        }
        XCTAssertEqual(url, URL(string: "https://3ds.example.com/challenge"))
        guard case .sessionCompleted = events[2] else {
            return XCTFail("Expected .sessionCompleted, got \(events[2])")
        }
    }

    func test_observe_errorActionType_propagatesProblemDetailsFromNextActionParams() async throws {
        // Per-attempt error must surface the params payload as a synthesized
        // ProblemDetails so the caller sees SOME context — previously
        // `.sessionFailed(nil)` dropped the payload silently.
        let errorJSON = """
        {
            "session_token": "sess_abc123",
            "status": "open",
            "next_action": {
                "action_type": "error",
                "params": {
                    "title": "Payment declined",
                    "detail": "Insufficient funds",
                    "error_code": "card_declined"
                }
            },
            "payment_amount": { "amount": "10.00", "currency": "EUR" }
        }
        """
        let mock = MockHTTPClient()
        let errorResponse = try decodeSession(errorJSON)
        mock.enqueue(errorResponse)

        let consumer = makeConsumer(mock: mock)
        var events: [ChannelEvent] = []
        do {
            for try await event in consumer.observe(sessionToken: "sess_abc123") {
                events.append(event)
            }
        } catch {}

        XCTAssertEqual(events.count, 1)
        guard case let .sessionFailed(details) = events[0] else {
            return XCTFail("Expected .sessionFailed, got \(events[0])")
        }
        XCTAssertNotNil(details, "ProblemDetails must be populated from params, not dropped")
        XCTAssertEqual(details?.title, "Payment declined")
        XCTAssertEqual(details?.detail, "Insufficient funds")
    }

    func test_observe_errorActionType_nestedErrorObject_extractsDetailAndType() async throws {
        // Production payment-processing nests the failure reason under
        // `params.error.{detail,type}` rather than RFC7807 top-level keys.
        // Without this path the SDK fell through to "unknown" and merchants
        // saw "Session failed: unknown" instead of the real reason.
        let errorJSON = """
        {
            "session_token": "sess_abc123",
            "status": "open",
            "next_action": {
                "action_type": "error",
                "params": {
                    "error": {
                        "detail": "The customer id is invalid",
                        "type": "technical_error"
                    }
                }
            },
            "payment_amount": { "amount": "10.00", "currency": "EUR" }
        }
        """
        let mock = MockHTTPClient()
        try mock.enqueue(decodeSession(errorJSON))
        let consumer = makeConsumer(mock: mock)
        var events: [ChannelEvent] = []
        for try await event in consumer.observe(sessionToken: "sess_abc123") {
            events.append(event)
        }
        XCTAssertEqual(events.count, 1)
        guard case let .sessionFailed(details) = events[0] else {
            return XCTFail("Expected .sessionFailed, got \(events[0])")
        }
        XCTAssertEqual(details?.title, "technical_error")
        XCTAssertEqual(details?.detail, "The customer id is invalid")
    }

    func test_observe_errorActionType_emptyParams_fallsBackToUnknownDetail() async throws {
        // No title/detail/error_code in params — synthesizer falls back to
        // "unknown" so downstream consumers still get a non-nil ProblemDetails.
        let errorJSON = """
        {
            "session_token": "sess_abc123",
            "status": "open",
            "next_action": { "action_type": "error" },
            "payment_amount": { "amount": "10.00", "currency": "EUR" }
        }
        """
        let mock = MockHTTPClient()
        try mock.enqueue(decodeSession(errorJSON))
        let consumer = makeConsumer(mock: mock)
        var events: [ChannelEvent] = []
        for try await event in consumer.observe(sessionToken: "sess_abc123") {
            events.append(event)
        }
        XCTAssertEqual(events.count, 1)
        guard case let .sessionFailed(details) = events[0] else {
            return XCTFail("Expected .sessionFailed, got \(events[0])")
        }
        XCTAssertEqual(details?.detail, "unknown")
    }
}
