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

    /// Production emits the 3DS challenge/ACS URL under `challengeUrl` (camelCase,
    /// PayProc path) — NOT `challenge_url`. `params` is a raw [String: AnyCodable]
    /// dict whose keys are not snake→camel converted, so the SDK must match the
    /// literal production key.
    private let threeDSChallengeCamelJSON = """
    {
        "session_token": "sess_abc123",
        "status": "open",
        "next_action": {
            "action_type": "threeDsChallenge",
            "params": { "challengeUrl": "https://3ds.example.com/challenge" }
        },
        "payment_amount": { "amount": "10.00", "currency": "EUR" }
    }
    """

    /// The 3DS-v2 event path emits the ACS URL under `acsURL`.
    private let threeDSChallengeACSJSON = """
    {
        "session_token": "sess_abc123",
        "status": "open",
        "next_action": {
            "action_type": "threeDsChallenge",
            "params": { "acsURL": "https://3ds.example.com/challenge" }
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

    func test_observe_threeDSAction_camelChallengeUrl_emitsChallengeReady() async throws {
        // Regression: production sends `challengeUrl` (camelCase), not
        // `challenge_url`. Before the fix the SDK read only `challenge_url`, so
        // the challenge was never surfaced and polling timed out.
        let mock = MockHTTPClient()
        try mock.enqueue(decodeSession(threeDSChallengeCamelJSON))
        try mock.enqueue(decodeSession(completedSessionJSON))

        let consumer = makeConsumer(mock: mock)
        var events: [ChannelEvent] = []
        for try await event in consumer.observe(sessionToken: "sess_abc123") {
            events.append(event)
        }

        guard case let .threeDSChallengeReady(url) = events[1] else {
            return XCTFail("Expected .threeDSChallengeReady for `challengeUrl`, got \(events[1])")
        }
        XCTAssertEqual(url, URL(string: "https://3ds.example.com/challenge"))
    }

    func test_observe_threeDSAction_acsURL_emitsChallengeReady() async throws {
        // Regression: the 3DS-v2 event path emits `acsURL`.
        let mock = MockHTTPClient()
        try mock.enqueue(decodeSession(threeDSChallengeACSJSON))
        try mock.enqueue(decodeSession(completedSessionJSON))

        let consumer = makeConsumer(mock: mock)
        var events: [ChannelEvent] = []
        for try await event in consumer.observe(sessionToken: "sess_abc123") {
            events.append(event)
        }

        guard case let .threeDSChallengeReady(url) = events[1] else {
            return XCTFail("Expected .threeDSChallengeReady for `acsURL`, got \(events[1])")
        }
        XCTAssertEqual(url, URL(string: "https://3ds.example.com/challenge"))
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

    // Validate URLs at the mapper. A hostile server response with
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

    func test_observe_expiredSession_emitsSessionFailed_doesNotTimeout() async throws {
        // Regression: an expired GET status must resolve the stream via a
        // terminal `.sessionFailed` (clean expiry), NOT keep polling until the
        // budget raises MollieError.timeout. Mirrors the legacy poll()'s
        // `status == .expired` terminal handling.
        let expiredJSON = """
        {
            "session_token": "sess_abc123",
            "status": "expired",
            "next_action": { "action_type": "none" },
            "payment_amount": { "amount": "10.00", "currency": "EUR" }
        }
        """
        let mock = MockHTTPClient()
        // Repeating: if expired were treated as non-terminal, the loop would
        // keep fetching this same response until the (short) budget timed out.
        try mock.enqueueRepeating(decodeSession(expiredJSON))

        let consumer = makeConsumer(
            mock: mock,
            intervals: [0.01, 0.01, 0.01],
            totalBudget: 0.2
        )
        var events: [ChannelEvent] = []
        for try await event in consumer.observe(sessionToken: "sess_abc123") {
            events.append(event)
        }

        XCTAssertEqual(events.count, 1, "expired must resolve immediately, not poll to timeout")
        guard case let .sessionFailed(details) = events[0] else {
            return XCTFail("Expected .sessionFailed for expired status, got \(events[0])")
        }
        XCTAssertEqual(details?.title, "session_expired")
    }

    func test_observeAttempt_expiredSession_emitsSessionFailed_doesNotTimeout() async throws {
        // Per-attempt path analogue: an expired status reached via
        // GET /checkout-attempts/ must resolve the stream terminally instead of
        // polling until MollieError.timeout.
        let expiredJSON = """
        {
            "session_token": "sess_abc123",
            "status": "expired",
            "next_action": { "action_type": "none" },
            "payment_amount": { "amount": "10.00", "currency": "EUR" }
        }
        """
        let mock = MockHTTPClient()
        try mock.enqueueRepeating(makeAttemptMap(token: "cat_abc", json: expiredJSON))

        let consumer = makeAttemptConsumer(
            mock: mock,
            intervals: [0.01, 0.01, 0.01],
            totalBudget: 0.2
        )
        var events: [ChannelEvent] = []
        for try await event in consumer.observeAttempt(sessionToken: "sess_abc123") {
            events.append(event)
        }

        XCTAssertEqual(events.count, 1, "expired must resolve immediately, not poll to timeout")
        guard case let .sessionFailed(details) = events[0] else {
            return XCTFail("Expected .sessionFailed for expired status, got \(events[0])")
        }
        XCTAssertEqual(details?.title, "session_expired")
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

    func test_observe_livePusherNeverFinishes_pollingStillReachesTerminal() async throws {
        // Regression: with a live PusherChannelsClient the
        // doorbell stream only finishes on a fatal disconnect. observe() must
        // run polling IN PARALLEL with the (best-effort) doorbell drain — never
        // await the socket before polling — or a healthy-but-quiet socket blocks
        // poll() forever and the payment hangs. `FakeChannelsClient` keeps its
        // stream open and never rings/finishes, standing in for that live socket.
        let mock = MockHTTPClient()
        try mock.enqueue(decodeSession(openSessionJSON))
        try mock.enqueue(decodeSession(completedSessionJSON))

        let fake = FakeChannelsClient()
        let poller = SessionPoller(
            httpClient: mock,
            sessionToken: "sess_abc123",
            schedule: PollingSchedule(intervals: [0.01], totalBudget: 5.0)
        )
        let consumer = SessionEventConsumer(channelsClient: fake, sessionPoller: poller)

        // Hard timeout: the pre-fix blocking code would hang here forever.
        let events = try await withTimeout(seconds: 5) {
            var collected: [ChannelEvent] = []
            for try await event in consumer.observe(sessionToken: "sess_abc123") {
                collected.append(event)
            }
            return collected
        }

        XCTAssertEqual(events.count, 2, "polling must proceed despite a live, never-finishing Pusher stream")
        guard case .sessionUpdated = events[0] else {
            return XCTFail("Expected .sessionUpdated, got \(events[0])")
        }
        guard case .sessionCompleted = events[1] else {
            return XCTFail("Expected .sessionCompleted, got \(events[1])")
        }
        XCTAssertEqual(fake.subscribeCount, 1, "the parallel subscription must be established")
        XCTAssertTrue(fake.didTearDown, "socket must be released after the poll loop ends")
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

    func test_observe_threeDSChallengeURL_snakeAndCamelKeys_bothEmitChallengeReady() async throws {
        // `params` is a raw [String: AnyCodable] dict whose keys are
        // NOT snake→camel converted, so the SDK matches literal wire keys. Both
        // the production `challengeUrl` (camelCase) and the dev-harness/mock
        // `challenge_url` (snake_case) must surface the challenge. A prior
        // version read ONLY `challenge_url`, silently dropping the real
        // production challenge → the WebView never presented and polling timed
        // out with `checkout-attempt-polling`.
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
        mock.enqueue(snakeResponse) // snake_case → .threeDSChallengeReady (mock/legacy fallback)
        mock.enqueue(camelResponse) // camelCase → .threeDSChallengeReady (production key)
        mock.enqueue(completed)

        let consumer = makeConsumer(mock: mock)
        var events: [ChannelEvent] = []
        for try await event in consumer.observe(sessionToken: "sess_abc123") {
            events.append(event)
        }

        // Each challenge poll yields a synthetic .sessionUpdated then
        // .threeDSChallengeReady; the final poll yields .sessionCompleted.
        XCTAssertEqual(events.count, 5)
        guard case let .threeDSChallengeReady(url1) = events[1] else {
            return XCTFail("Expected .threeDSChallengeReady for snake_case key, got \(events[1])")
        }
        XCTAssertEqual(url1.absoluteString, "https://3ds.example.com/acs")
        guard case let .threeDSChallengeReady(url2) = events[3] else {
            return XCTFail("Expected .threeDSChallengeReady for camelCase key, got \(events[3])")
        }
        XCTAssertEqual(url2.absoluteString, "https://3ds.example.com/acs")
        guard case .sessionCompleted = events[4] else {
            return XCTFail("Expected .sessionCompleted, got \(events[4])")
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

    // MARK: - observeAttempt(sessionToken:) — P5 concurrent doorbell+poll merge

    /// Controllable fake channels client. The test pushes doorbells through
    /// `ring(_:)` and can finish/fail the stream via `finish()` (Pusher-fatal
    /// simulation). `subscribeCount` / `tornDown` let tests assert lifecycle.
    private final class FakeChannelsClient: MollieChannelsClient, @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: AsyncStream<ChannelDoorbell>.Continuation?
        private(set) var subscribeCount = 0
        private(set) var tornDown = false

        func subscribe(to _: String) async throws -> AsyncStream<ChannelDoorbell> {
            lock.lock()
            subscribeCount += 1
            lock.unlock()
            return AsyncStream { continuation in
                lock.lock()
                self.continuation = continuation
                lock.unlock()
                continuation.onTermination = { [weak self] _ in
                    guard let self else { return }
                    lock.lock()
                    tornDown = true
                    lock.unlock()
                }
            }
        }

        func unsubscribe(from _: String) async {
            lock.lock()
            tornDown = true
            lock.unlock()
        }

        func disconnect() async {
            lock.lock()
            tornDown = true
            lock.unlock()
        }

        /// Deliver a doorbell to the live subscription.
        func ring(eventId: Int? = nil) {
            lock.lock()
            let cont = continuation
            lock.unlock()
            cont?.yield(ChannelDoorbell(eventId: eventId))
        }

        /// Finish the doorbell stream (simulates Pusher-fatal → consumer
        /// fails over to polling).
        func finish() {
            lock.lock()
            let cont = continuation
            lock.unlock()
            cont?.finish()
        }

        var didTearDown: Bool {
            lock.lock()
            defer { lock.unlock() }
            return tornDown
        }
    }

    private func makeMergeConsumer(
        mock: MockHTTPClient,
        channelsClient: any MollieChannelsClient,
        checkoutAttemptToken: String = "cat_abc",
        intervals: [TimeInterval] = [0.01],
        totalBudget: TimeInterval = 5.0
    ) -> SessionEventConsumer {
        let poller = SessionPoller(
            httpClient: mock,
            sessionToken: "sess_abc123",
            checkoutAttemptToken: checkoutAttemptToken,
            schedule: PollingSchedule(intervals: intervals, totalBudget: totalBudget)
        )
        return SessionEventConsumer(channelsClient: channelsClient, sessionPoller: poller)
    }

    /// A per-attempt map carrying an explicit `event_id` on `next_action` so
    /// dedup tests can drive distinct/identical events deterministically.
    private func makeAttemptMap(token: String, status: String, eventId: Int) throws -> CheckoutAttemptsStateMap {
        let json = """
        {
            "session_token": "sess_abc123",
            "status": "\(status)",
            "next_action": { "action_type": "await", "event_id": \(eventId) },
            "payment_amount": { "amount": "10.00", "currency": "EUR" }
        }
        """
        return try makeAttemptMap(token: token, json: json)
    }

    func test_observeAttempt_doorbell_triggersFetchAndEmit() async throws {
        // A doorbell must drive a re-fetch+diff that emits, even though the
        // schedule's poll budget is long enough that the timer loop wouldn't
        // have fired yet. The fetch source is the doorbell, not the timer.
        let mock = MockHTTPClient()
        // First fetch (open) returned on the doorbell; second (completed)
        // returned on the next doorbell, which finishes the stream.
        try mock.enqueue(makeAttemptMap(token: "cat_abc", status: "open", eventId: 1))
        try mock.enqueue(makeAttemptMap(token: "cat_abc", status: "completed", eventId: 2))

        let fake = FakeChannelsClient()
        let consumer = makeMergeConsumer(
            mock: mock,
            channelsClient: fake,
            intervals: [60.0], // long: timer must not fire during the test
            totalBudget: 120.0
        )

        let collectTask = Task { () -> [ChannelEvent] in
            var events: [ChannelEvent] = []
            for try await event in consumer.observeAttempt(sessionToken: "sess_abc123") {
                events.append(event)
            }
            return events
        }

        // Give the subscription a beat to install, then ring twice.
        try await Task.sleep(nanoseconds: 50_000_000)
        fake.ring(eventId: 1)
        try await Task.sleep(nanoseconds: 50_000_000)
        fake.ring(eventId: 2)

        let events = try await collectTask.value
        XCTAssertEqual(events.count, 2, "expected one .sessionUpdated then .sessionCompleted")
        guard case .sessionUpdated = events[0] else {
            return XCTFail("Expected .sessionUpdated from first doorbell, got \(events[0])")
        }
        guard case .sessionCompleted = events[1] else {
            return XCTFail("Expected .sessionCompleted from second doorbell, got \(events[1])")
        }
    }

    func test_observeAttempt_pusherFatal_fallsBackToPolling_reachesTerminal() async throws {
        // When the doorbell stream finishes (Pusher-fatal), the consumer must
        // fail over to the timer-based pollAttempt loop and still reach a
        // terminal state. Failover is one-shot/one-directional (Pusher→poll).
        let mock = MockHTTPClient()
        try mock.enqueue(makeAttemptMap(token: "cat_abc", status: "open", eventId: 1))
        try mock.enqueue(makeAttemptMap(token: "cat_abc", status: "completed", eventId: 2))

        let fake = FakeChannelsClient()
        let consumer = makeMergeConsumer(
            mock: mock,
            channelsClient: fake,
            intervals: [0.01],
            totalBudget: 5.0
        )

        let collectTask = Task { () -> [ChannelEvent] in
            var events: [ChannelEvent] = []
            for try await event in consumer.observeAttempt(sessionToken: "sess_abc123") {
                events.append(event)
            }
            return events
        }

        // Let it subscribe, then immediately kill the Pusher stream — no
        // doorbell ever arrives, so only the poll fallback can finish this.
        try await Task.sleep(nanoseconds: 30_000_000)
        fake.finish()

        let events = try await collectTask.value
        XCTAssertTrue(events.contains {
            if case .sessionCompleted = $0 {
                true
            } else {
                false
            }
        },
        "poll fallback must reach .sessionCompleted, got \(events)")
    }

    func test_observeAttempt_watchdog_fetchesWhenIdle() async throws {
        // No doorbell ever rings, but the stream stays open. The inactivity
        // watchdog must fire a fetch and drive the flow to terminal. Use a
        // short watchdog override so the test stays fast.
        let mock = MockHTTPClient()
        try mock.enqueue(makeAttemptMap(token: "cat_abc", status: "completed", eventId: 1))

        let fake = FakeChannelsClient()
        let consumer = makeMergeConsumer(
            mock: mock,
            channelsClient: fake,
            intervals: [60.0], // timer loop must not be what fetches here
            totalBudget: 120.0
        )

        let events = try await withTimeout(seconds: 5) {
            var collected: [ChannelEvent] = []
            for try await event in consumer.observeAttempt(
                sessionToken: "sess_abc123",
                watchdogInterval: 0.1
            ) {
                collected.append(event)
            }
            return collected
        }

        XCTAssertTrue(events.contains {
            if case .sessionCompleted = $0 {
                true
            } else {
                false
            }
        },
        "watchdog must drive a fetch to terminal, got \(events)")
    }

    func test_observeAttempt_dedup_preventsDoubleEmitAcrossSources() async throws {
        // Two doorbells both return the SAME eventId — the second must be
        // deduped (consumer owns one eventId dedup across all fetch sources).
        // A third doorbell with a new eventId+completed status finishes.
        let mock = MockHTTPClient()
        try mock.enqueue(makeAttemptMap(token: "cat_abc", status: "open", eventId: 7))
        try mock.enqueue(makeAttemptMap(token: "cat_abc", status: "open", eventId: 7)) // dup
        try mock.enqueue(makeAttemptMap(token: "cat_abc", status: "completed", eventId: 8))

        let fake = FakeChannelsClient()
        let consumer = makeMergeConsumer(
            mock: mock,
            channelsClient: fake,
            intervals: [60.0],
            totalBudget: 120.0
        )

        let collectTask = Task { () -> [ChannelEvent] in
            var events: [ChannelEvent] = []
            for try await event in consumer.observeAttempt(sessionToken: "sess_abc123") {
                events.append(event)
            }
            return events
        }

        try await Task.sleep(nanoseconds: 50_000_000)
        fake.ring(eventId: 7)
        try await Task.sleep(nanoseconds: 50_000_000)
        fake.ring(eventId: 7)
        try await Task.sleep(nanoseconds: 50_000_000)
        fake.ring(eventId: 8)

        let events = try await collectTask.value
        // One update (eventId 7), the dup is dropped, then completed (eventId 8).
        XCTAssertEqual(events.count, 2, "dup eventId must not double-emit, got \(events)")
        guard case .sessionUpdated = events[0] else {
            return XCTFail("Expected .sessionUpdated, got \(events[0])")
        }
        guard case .sessionCompleted = events[1] else {
            return XCTFail("Expected .sessionCompleted, got \(events[1])")
        }
    }

    func test_observeAttempt_terminalWithSameEventId_stillEmits() async throws {
        // Regression: the eventId dedup must NOT swallow a terminal
        // response that reuses the previous eventId. A non-terminal (open)
        // eventId=5 followed by a completed eventId=5 must still emit the
        // terminal `.sessionCompleted` — terminal status is authoritative over
        // the eventId duplicate short-circuit. Before the fix the second
        // response was dropped as a "duplicate" and the stream resolved by
        // timeout instead of success.
        let openSame = """
        {
            "session_token": "sess_abc123",
            "status": "open",
            "next_action": { "action_type": "await", "event_id": 5 },
            "payment_amount": { "amount": "10.00", "currency": "EUR" }
        }
        """
        let completedSame = """
        {
            "session_token": "sess_abc123",
            "status": "completed",
            "next_action": { "action_type": "none", "event_id": 5 },
            "payment_amount": { "amount": "10.00", "currency": "EUR" }
        }
        """
        let mock = MockHTTPClient()
        try mock.enqueue(makeAttemptMap(token: "cat_abc", json: openSame))
        try mock.enqueue(makeAttemptMap(token: "cat_abc", json: completedSame))

        let fake = FakeChannelsClient()
        let consumer = makeMergeConsumer(
            mock: mock,
            channelsClient: fake,
            intervals: [60.0],
            totalBudget: 120.0
        )

        let collectTask = Task { () -> [ChannelEvent] in
            var events: [ChannelEvent] = []
            for try await event in consumer.observeAttempt(sessionToken: "sess_abc123") {
                events.append(event)
            }
            return events
        }

        // The seeded initial fetch (fired the moment the doorbell phase starts)
        // consumes the first enqueued response (open, eventId 5) and emits
        // .sessionUpdated. A single doorbell then drives the second fetch
        // (completed, SAME eventId 5) which must still emit the terminal event.
        try await Task.sleep(nanoseconds: 50_000_000)
        fake.ring(eventId: 5)

        let events = try await collectTask.value
        XCTAssertEqual(events.count, 2, "terminal with reused eventId must not be deduped, got \(events)")
        guard case .sessionUpdated = events[0] else {
            return XCTFail("Expected .sessionUpdated first, got \(events[0])")
        }
        guard case .sessionCompleted = events[1] else {
            return XCTFail("Expected .sessionCompleted even with reused eventId, got \(events[1])")
        }
    }

    func test_observeAttempt_cancellation_tearsDownSubscription() async throws {
        let mock = MockHTTPClient()
        try mock.enqueueRepeating(makeAttemptMap(token: "cat_abc", status: "open", eventId: 1))

        let fake = FakeChannelsClient()
        let consumer = makeMergeConsumer(
            mock: mock,
            channelsClient: fake,
            intervals: [60.0],
            totalBudget: 120.0
        )

        let task = Task {
            for try await _ in consumer.observeAttempt(sessionToken: "sess_abc123") {}
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(fake.subscribeCount, 1)
        task.cancel()
        // Allow teardown to propagate.
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(fake.didTearDown, "subscription must be torn down on cancellation")
    }

    func test_observeAttempt_noOpChannels_matchesLegacyPollOnly() async throws {
        // With the NoOp client (empty stream), behavior must be IDENTICAL to
        // the legacy poll-only flow: the doorbell stream finishes immediately
        // and the poll fallback drives the whole sequence.
        let mock = MockHTTPClient()
        try mock.enqueue(makeAttemptMap(token: "cat_abc", json: threeDSChallengeJSON))
        try mock.enqueue(makeAttemptMap(token: "cat_abc", json: completedSessionJSON))

        let consumer = makeAttemptConsumer(mock: mock) // uses NoOpChannelsClient
        var events: [ChannelEvent] = []
        for try await event in consumer.observeAttempt(sessionToken: "sess_abc123") {
            events.append(event)
        }

        // Same as the pre-P5 poll-only expectation: synthetic .sessionUpdated,
        // then .threeDSChallengeReady, then .sessionCompleted.
        XCTAssertEqual(events.count, 3)
        guard case .sessionUpdated = events[0] else {
            return XCTFail("Expected .sessionUpdated before action event, got \(events[0])")
        }
        guard case .threeDSChallengeReady = events[1] else {
            return XCTFail("Expected .threeDSChallengeReady, got \(events[1])")
        }
        guard case .sessionCompleted = events[2] else {
            return XCTFail("Expected .sessionCompleted, got \(events[2])")
        }
    }

    func test_observeAttempt_doorbell_preservesYieldEventsOrdering() async throws {
        // A doorbell that fetches a 3DS-challenge response must still emit the
        // synthetic .sessionUpdated BEFORE .threeDSChallengeReady, so the
        // coordinator's lastSession (merchantReturnURL) is populated before the
        // action event reaches the WebView. This is the doorbell-path analogue
        // of the existing poll-path ordering guarantee.
        let mock = MockHTTPClient()
        try mock.enqueue(makeAttemptMap(token: "cat_abc", json: threeDSChallengeJSON))
        try mock.enqueue(makeAttemptMap(token: "cat_abc", json: completedSessionJSON))

        let fake = FakeChannelsClient()
        let consumer = makeMergeConsumer(
            mock: mock,
            channelsClient: fake,
            intervals: [60.0],
            totalBudget: 120.0
        )

        let collectTask = Task { () -> [ChannelEvent] in
            var events: [ChannelEvent] = []
            for try await event in consumer.observeAttempt(sessionToken: "sess_abc123") {
                events.append(event)
            }
            return events
        }

        try await Task.sleep(nanoseconds: 50_000_000)
        fake.ring()
        try await Task.sleep(nanoseconds: 50_000_000)
        fake.ring()

        let events = try await collectTask.value
        XCTAssertEqual(events.count, 3)
        guard case .sessionUpdated = events[0] else {
            return XCTFail("Expected .sessionUpdated before action event, got \(events[0])")
        }
        guard case .threeDSChallengeReady = events[1] else {
            return XCTFail("Expected .threeDSChallengeReady second, got \(events[1])")
        }
        guard case .sessionCompleted = events[2] else {
            return XCTFail("Expected .sessionCompleted third, got \(events[2])")
        }
    }

    func test_observeAttempt_subscribesAndSeedsInitialFetch_noDoorbellNeeded() async throws {
        // Subscribe-then-initial-fetch: the single session-scoped
        // doorbell can fire before the SDK has finished subscribing and be lost;
        // the server is then already terminal at t=0 but no doorbell will ever
        // ring. With a long watchdog interval the consumer must NOT wait ~15s —
        // it must seed exactly one fetch right after subscribing and reach
        // terminal immediately, at parity with the poll-only path's leading poll.
        let mock = MockHTTPClient()
        try mock.enqueue(makeAttemptMap(token: "cat_abc", status: "completed", eventId: 1))

        let fake = FakeChannelsClient()
        let consumer = makeMergeConsumer(
            mock: mock,
            channelsClient: fake,
            intervals: [60.0], // timer loop must not be what fetches here
            totalBudget: 120.0
        )

        // Long watchdog: if the initial fetch were NOT seeded, the only path to
        // a fetch would be the 5s watchdog → withTimeout(2s) would fail. The
        // test passing under a 2s budget proves the seeded fetch ran promptly.
        let events = try await withTimeout(seconds: 2) {
            var collected: [ChannelEvent] = []
            for try await event in consumer.observeAttempt(
                sessionToken: "sess_abc123",
                watchdogInterval: 5.0 // far longer than the 2s test budget
            ) {
                collected.append(event)
            }
            return collected
        }

        XCTAssertEqual(fake.subscribeCount, 1, "must subscribe before the initial fetch")
        XCTAssertEqual(events.count, 1)
        guard case .sessionCompleted = events[0] else {
            return XCTFail("Expected .sessionCompleted from the seeded initial fetch, got \(events[0])")
        }
    }

    func test_observeAttempt_quietConnectedSocket_timesOutWithinBudget() async throws {
        // Doorbell-phase overall budget: a healthy-but-quiet Pusher
        // socket never finishes its stream (so failover to pollAttempt never
        // runs) and the session never reaches a terminal state. Without an
        // overall deadline on the doorbell phase the consumer would run
        // unbounded. The phase must enforce the poller's totalBudget and raise
        // MollieError.timeout — parity with the poll-only path which always
        // terminated within totalBudget.
        let mock = MockHTTPClient()
        // Every fetch returns a non-terminal (open) response; no terminal ever.
        try mock.enqueueRepeating(makeAttemptMap(token: "cat_abc", status: "open", eventId: 1))

        let fake = FakeChannelsClient() // never finished → socket stays "connected"
        let consumer = makeMergeConsumer(
            mock: mock,
            channelsClient: fake,
            intervals: [60.0], // poll timer must not be what ends this
            totalBudget: 0.3 // short overall budget for a fast test
        )

        // Drive watchdog fetches (non-terminal) so the phase stays "alive" and
        // only the overall budget can end it. withTimeout guards against a hang.
        let result: Result<[ChannelEvent], Error> = await {
            do {
                let events = try await withTimeout(seconds: 5) {
                    var collected: [ChannelEvent] = []
                    for try await event in consumer.observeAttempt(
                        sessionToken: "sess_abc123",
                        watchdogInterval: 0.05
                    ) {
                        collected.append(event)
                    }
                    return collected
                }
                return .success(events)
            } catch {
                return .failure(error)
            }
        }()

        switch result {
        case let .success(events):
            XCTFail("Expected MollieError.timeout, stream finished cleanly with \(events)")
        case let .failure(error):
            guard case let MollieError.timeout(operation) = error else {
                return XCTFail("Expected MollieError.timeout, got \(error)")
            }
            XCTAssertEqual(operation, "checkout-attempt-doorbell")
        }
    }

    // MARK: - observeCardPayment(sessionToken:) — concurrent session-completion poll

    // These tests pin the card-3DS regression fix: a checkout-attempt projection
    // can stall at AUTHENTICATION_PENDING (no 2nd doorbell, no completion event)
    // while the underlying SESSION reaches `completed`. observeCardPayment runs
    // the attempt path AND a concurrent GET /sessions completion poll, racing to
    // the first terminal state. The type-routed MockHTTPClient serves each
    // producer from one interleaved queue: CheckoutAttemptsStateMap for the
    // attempt fetches (via setDefault) and SessionResponse for the session GET.

    /// The core regression. The attempt path never reaches terminal (stuck open
    /// forever) while GET /sessions reports `completed`. observeAttempt ALONE
    /// would poll to `MollieError.timeout`; observeCardPayment must instead yield
    /// `.sessionCompleted` from the concurrent session poll and NOT throw.
    func test_observeCardPayment_attemptStuck_sessionCompletes_emitsCompletedNotTimeout() async throws {
        let mock = MockHTTPClient()
        // Every GET /checkout-attempts stays non-terminal (stuck). setDefault
        // serves the CAT type on every attempt fetch WITHOUT a global `repeating`
        // that would also (wrongly) answer the session GET's SessionResponse.
        try mock.setDefault(makeAttemptMap(token: "cat_abc", status: "open", eventId: 1))
        // The session GET reaches completed — the fix's authority. Positional
        // enqueue; the type-routed mock hands this only to the session producer.
        try mock.enqueue(decodeSession(completedSessionJSON))

        let consumer = makeAttemptConsumer(
            mock: mock,
            intervals: [0.01],
            totalBudget: 5.0 // attempt base budget must NOT expire during the test
        )

        let events = try await withTimeout(seconds: 5) {
            var collected: [ChannelEvent] = []
            for try await event in consumer.observeCardPayment(
                sessionToken: "sess_abc123",
                watchdogInterval: 5.0,
                challengeCompletionBudget: 2.0
            ) {
                collected.append(event)
            }
            return collected
        }

        // The ONLY source of `.sessionCompleted` here is the session poll — the
        // attempt map is stuck open — so its presence proves the fix.
        XCTAssertTrue(
            events.contains {
                if case .sessionCompleted = $0 {
                    true
                } else {
                    false
                }
            },
            "concurrent session poll must resolve the stuck attempt via .sessionCompleted, got \(events)"
        )
        guard case .sessionCompleted = events.last else {
            return XCTFail("Expected final event .sessionCompleted, got \(String(describing: events.last))")
        }
    }

    /// Challenge-aware budget hand-off. The attempt path surfaces a hosted
    /// pay.mollie.nl prepare-authentication redirect (→ `.redirectRequired`,
    /// marking a challenge in flight) then times out on its tiny base budget.
    /// Because a challenge was seen, that attempt timeout is SWALLOWED and the
    /// (longer) session poll becomes the authority — which then completes.
    func test_observeCardPayment_challengeSeen_attemptTimeoutSwallowed_sessionCompletes() async throws {
        let mock = MockHTTPClient()
        // Hosted pay.mollie.nl URL → SessionEventMapper maps a `redirect`
        // next-action to `.redirectRequired`; event_id lets the attempt path
        // dedup so the redirect is not re-emitted on every poll tick.
        let hostedRedirectJSON = """
        {
            "session_token": "sess_abc123",
            "status": "open",
            "next_action": {
                "action_type": "redirect",
                "event_id": 1,
                "params": { "url": "https://pay.mollie.nl/payment/prepare-authentication/abc?no_redirect=true" }
            },
            "payment_amount": { "amount": "10.00", "currency": "EUR" }
        }
        """
        try mock.setDefault(makeAttemptMap(token: "cat_abc", json: hostedRedirectJSON))
        // Session GET: open first (fetched but not yielded — non-terminal), then
        // completed one interval later. Both consumed only by the session producer.
        try mock.enqueue(decodeSession(openSessionJSON))
        try mock.enqueue(decodeSession(completedSessionJSON))

        let consumer = makeAttemptConsumer(
            mock: mock,
            intervals: [0.01],
            totalBudget: 0.3 // tiny attempt base budget → attempt path times out
        )

        let events = try await withTimeout(seconds: 5) {
            var collected: [ChannelEvent] = []
            for try await event in consumer.observeCardPayment(
                sessionToken: "sess_abc123",
                watchdogInterval: 5.0,
                challengeCompletionBudget: 2.0
            ) {
                collected.append(event)
            }
            return collected
        }

        XCTAssertTrue(
            events.contains {
                if case .redirectRequired = $0 {
                    true
                } else {
                    false
                }
            },
            "attempt path must surface the hosted redirect (challenge) before timing out, got \(events)"
        )
        guard case .sessionCompleted = events.last else {
            return XCTFail(
                "Expected final .sessionCompleted (attempt timeout swallowed after challenge), " +
                    "got \(String(describing: events.last))"
            )
        }
    }

    /// Fast-fail with no challenge. The attempt path is stuck open with NO
    /// challenge/redirect ever, so its base-budget timeout must surface
    /// immediately as `MollieError.timeout` — it must NOT be swallowed and wait
    /// out the far longer challenge-completion budget.
    func test_observeCardPayment_noChallenge_attemptTimeout_failsFast() async throws {
        let mock = MockHTTPClient()
        // Distinct per-type defaults: attempt stays open (never terminal, no
        // challenge) and the session GET also stays open (never completes).
        try mock.setDefault(makeAttemptMap(token: "cat_abc", status: "open", eventId: 1))
        try mock.setDefault(decodeSession(openSessionJSON))

        let consumer = makeAttemptConsumer(
            mock: mock,
            intervals: [0.01],
            totalBudget: 0.2 // attempt base budget → fast timeout, no challenge
        )

        let start = Date()
        let result: Result<[ChannelEvent], Error> = await {
            do {
                let events = try await withTimeout(seconds: 5) {
                    var collected: [ChannelEvent] = []
                    for try await event in consumer.observeCardPayment(
                        sessionToken: "sess_abc123",
                        watchdogInterval: 5.0,
                        challengeCompletionBudget: 5.0 // long — must NOT be what ends the test
                    ) {
                        collected.append(event)
                    }
                    return collected
                }
                return .success(events)
            } catch {
                return .failure(error)
            }
        }()
        let elapsed = Date().timeIntervalSince(start)

        switch result {
        case let .success(events):
            XCTFail("Expected a fast MollieError.timeout with no challenge, got \(events)")
        case let .failure(error):
            guard case MollieError.timeout = error else {
                return XCTFail("Expected MollieError.timeout, got \(error)")
            }
            XCTAssertLessThan(
                elapsed, 2.0,
                "must fail fast on the attempt base budget, not wait the full 5s challenge budget"
            )
        }
    }

    /// Disabled budget parity. `challengeCompletionBudget: 0` must disable the
    /// concurrent session poll entirely, so observeCardPayment behaves EXACTLY
    /// like observeAttempt: a stuck attempt times out. No SessionResponse is
    /// served — if the session poll ran anyway it would trip the mock's
    /// queue-empty XCTFail, making the regression loud.
    func test_observeCardPayment_zeroBudget_behavesLikeObserveAttempt_stuckTimesOut() async throws {
        let mock = MockHTTPClient()
        try mock.setDefault(makeAttemptMap(token: "cat_abc", status: "open", eventId: 1))

        let consumer = makeAttemptConsumer(
            mock: mock,
            intervals: [0.01],
            totalBudget: 0.2
        )

        let result: Result<[ChannelEvent], Error> = await {
            do {
                let events = try await withTimeout(seconds: 5) {
                    var collected: [ChannelEvent] = []
                    for try await event in consumer.observeCardPayment(
                        sessionToken: "sess_abc123",
                        watchdogInterval: 5.0,
                        challengeCompletionBudget: 0 // disables the session poll
                    ) {
                        collected.append(event)
                    }
                    return collected
                }
                return .success(events)
            } catch {
                return .failure(error)
            }
        }()

        switch result {
        case let .success(events):
            XCTFail("Expected MollieError.timeout (session poll disabled at budget 0), got \(events)")
        case let .failure(error):
            guard case MollieError.timeout = error else {
                return XCTFail("Expected MollieError.timeout, got \(error)")
            }
        }
    }

    /// Runs `body` with a hard wall-clock timeout so a hung stream fails the
    /// test instead of hanging the suite.
    private func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        _ body: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await body() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw MollieError.timeout(operation: "test-withTimeout")
            }
            guard let result = try await group.next() else {
                throw MollieError.timeout(operation: "test-withTimeout-empty")
            }
            group.cancelAll()
            return result
        }
    }
}
