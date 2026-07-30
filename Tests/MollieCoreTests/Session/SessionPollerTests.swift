import XCTest
@testable import MollieCore

final class SessionPollerTests: XCTestCase {
    private let sessionToken = "sess_abc123"

    // MARK: - Helpers

    private func makeResponse(status: SessionStatus) -> SessionResponse {
        let json = """
        {
            "session_token": "sess_abc123",
            "status": "\(status.rawValue)",
            "next_action": { "action_type": "await" },
            "payment_amount": { "amount": "10.00", "currency": "EUR" }
        }
        """
        // swiftlint:disable:next force_try
        return try! MollieJSONDecoder().decode(SessionResponse.self, from: Data(json.utf8))
    }

    private func makeFastSchedule(totalBudget: TimeInterval = 1.0) -> PollingSchedule {
        // 10ms intervals keep tests fast.
        PollingSchedule(intervals: Array(repeating: 0.01, count: 20), totalBudget: totalBudget)
    }

    private func collect(
        from stream: AsyncThrowingStream<SessionResponse, Error>
    ) async throws -> [SessionResponse] {
        var collected: [SessionResponse] = []
        for try await response in stream {
            collected.append(response)
        }
        return collected
    }

    // MARK: - Terminal status

    func test_poll_terminalCompletedStatus_finishesStream() async throws {
        let mock = MockHTTPClient()
        mock.enqueue(makeResponse(status: .completed))
        let poller = SessionPoller(httpClient: mock, sessionToken: sessionToken, schedule: makeFastSchedule())

        let results = try await collect(from: poller.poll())

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.status, .known(.completed))
    }

    func test_poll_terminalExpiredStatus_finishesStream() async throws {
        let mock = MockHTTPClient()
        mock.enqueue(makeResponse(status: .expired))
        let poller = SessionPoller(httpClient: mock, sessionToken: sessionToken, schedule: makeFastSchedule())

        let results = try await collect(from: poller.poll())

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.status, .known(.expired))
    }

    func test_poll_nonTerminal_pollsAgainUntilTerminal() async throws {
        let mock = MockHTTPClient()
        mock.enqueue(makeResponse(status: .open))
        mock.enqueue(makeResponse(status: .open))
        mock.enqueue(makeResponse(status: .completed))
        let poller = SessionPoller(httpClient: mock, sessionToken: sessionToken, schedule: makeFastSchedule())

        let results = try await collect(from: poller.poll())

        XCTAssertEqual(results.count, 3)
        XCTAssertEqual(results.map(\.status), [.known(.open), .known(.open), .known(.completed)])
    }

    // MARK: - Timeout

    func test_poll_timeoutExceeded_throwsMollieError() async {
        let mock = MockHTTPClient()
        mock.enqueueRepeating(makeResponse(status: .open))
        let schedule = PollingSchedule(intervals: [0.01, 0.01, 0.01], totalBudget: 0.05)
        let poller = SessionPoller(httpClient: mock, sessionToken: sessionToken, schedule: schedule)

        do {
            _ = try await collect(from: poller.poll())
            XCTFail("Expected MollieError.timeout to be thrown")
        } catch let MollieError.timeout(operation) {
            XCTAssertEqual(operation, "session-polling")
        } catch {
            XCTFail("Expected MollieError.timeout but got \(error)")
        }
    }

    /// A single `fetch()` must be bounded by the REMAINING poll budget.
    /// The shared production `URLSession` has `waitsForConnectivity = true` +
    /// `timeoutIntervalForResource = 120`, so one fetch can block ~120s waiting
    /// for connectivity. The between-fetches budget check can't cut that off —
    /// it only runs once the stalled fetch returns. This test proves the fetch
    /// itself is deadline-bounded: with a tiny finite budget and a fetch that
    /// stalls far longer, the stream must throw `.timeout` FAST (well under the
    /// stall) rather than hang for the full stall duration.
    func test_poll_singleStalledFetch_boundedByRemainingBudget() async {
        final class StallingHTTPClient: HTTPClient, @unchecked Sendable {
            func perform<T: Decodable>(_: Endpoint<T>) async throws -> T {
                // Stall far longer than the poll budget. Task.sleep is
                // cancellation-aware, mirroring URLSession's async cancel
                // behaviour when the deadline task tears the group down.
                try await Task.sleep(nanoseconds: 5_000_000_000) // 5s
                throw MollieError.network(URLError(.timedOut))
            }
        }
        // Small finite budget; a stalled fetch would otherwise run ~5s.
        let schedule = PollingSchedule(intervals: [0.01], totalBudget: 0.3)
        let poller = SessionPoller(httpClient: StallingHTTPClient(), sessionToken: sessionToken, schedule: schedule)

        let start = ContinuousClock.now
        do {
            _ = try await collect(from: poller.poll())
            XCTFail("Expected MollieError.timeout to be thrown")
        } catch let MollieError.timeout(operation) {
            XCTAssertEqual(operation, "session-polling")
        } catch {
            XCTFail("Expected MollieError.timeout but got \(error)")
        }
        let elapsed = start.duration(to: .now)
        // Pre-fix: the fetch runs its full 5s stall before any budget check,
        // so elapsed ≈ 5s. Post-fix: the fetch is capped at the remaining
        // budget (~0.3s), so the stream fails fast. 1s gives generous
        // scheduler headroom while staying well under the 5s stall.
        XCTAssertLessThan(elapsed, .seconds(1),
                          "A single stalled fetch must be bounded by the remaining budget, not hang for its full duration")
    }

    // MARK: - Cancellation

    func test_poll_cancellation_stopsImmediately() async throws {
        let mock = MockHTTPClient()
        mock.enqueueRepeating(makeResponse(status: .open))
        // Long intervals so cancellation wins the race.
        let schedule = PollingSchedule(intervals: Array(repeating: 1.0, count: 50), totalBudget: 60)
        let poller = SessionPoller(httpClient: mock, sessionToken: sessionToken, schedule: schedule)

        let task = Task {
            try await collect(from: poller.poll())
        }
        // Give the task a moment to start, then cancel.
        try await Task.sleep(nanoseconds: 20_000_000) // 20ms
        task.cancel()

        let countAtCancel = mock.callCount
        // Awaiting the cancelled task should complete promptly (no further requests).
        _ = await task.result
        try await Task.sleep(nanoseconds: 50_000_000) // 50ms
        XCTAssertLessThanOrEqual(mock.callCount, countAtCancel + 1)
    }

    // MARK: - pollAttempt: token lookup

    private func makeMap(token: String, status: SessionStatus, eventId: Int? = nil) -> CheckoutAttemptsStateMap {
        let json = """
        {
            "\(token)": {
                "session_token": "sess_abc123",
                "status": "\(status.rawValue)",
                "next_action": { "action_type": "await"\(eventId.map { ", \"event_id\": \($0)" } ?? "") },
                "payment_amount": { "amount": "10.00", "currency": "EUR" }
            }
        }
        """
        // swiftlint:disable:next force_try
        return try! MollieJSONDecoder().decode(CheckoutAttemptsStateMap.self, from: Data(json.utf8))
    }

    func test_pollAttempt_findsTokenInMap_yields() async throws {
        let mock = MockHTTPClient()
        let map1 = makeMap(token: "cat_abc", status: .open, eventId: 1)
        let map2 = makeMap(token: "cat_abc", status: .completed, eventId: 2)
        mock.enqueue(map1)
        mock.enqueue(map2)
        let poller = SessionPoller(
            httpClient: mock,
            sessionToken: sessionToken,
            checkoutAttemptToken: "cat_abc",
            schedule: makeFastSchedule()
        )
        var results: [SessionResponse] = []
        for try await response in poller.pollAttempt() {
            results.append(response)
            if results.count == 2 {
                break
            }
        }
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results[0].status, .known(.open))
        XCTAssertEqual(results[1].status, .known(.completed))
    }

    func test_pollAttempt_missingToken_treatsAsTransient() async throws {
        let mock = MockHTTPClient()
        // First poll: token absent (empty map)
        mock.enqueue(CheckoutAttemptsStateMap())
        // Second poll: token present
        let map = makeMap(token: "cat_abc", status: .open, eventId: 1)
        mock.enqueue(map)
        let poller = SessionPoller(
            httpClient: mock,
            sessionToken: sessionToken,
            checkoutAttemptToken: "cat_abc",
            schedule: makeFastSchedule()
        )
        var results: [SessionResponse] = []
        for try await response in poller.pollAttempt() {
            results.append(response)
            break
        }
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].status, .known(.open))
    }

    func test_pollAttempt_deduplicatesOnEventId() async throws {
        let mock = MockHTTPClient()
        // Three polls with same eventId — only the first should be yielded.
        let mapA = makeMap(token: "cat_abc", status: .open, eventId: 42)
        let mapB = makeMap(token: "cat_abc", status: .open, eventId: 42)
        let mapC = makeMap(token: "cat_abc", status: .open, eventId: 99)
        mock.enqueue(mapA)
        mock.enqueue(mapB)
        mock.enqueue(mapC)
        let poller = SessionPoller(
            httpClient: mock,
            sessionToken: sessionToken,
            checkoutAttemptToken: "cat_abc",
            schedule: makeFastSchedule()
        )
        var results: [SessionResponse] = []
        for try await response in poller.pollAttempt() {
            results.append(response)
            if results.count == 2 {
                break
            }
        }
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results[0].nextAction.eventId, 42)
        XCTAssertEqual(results[1].nextAction.eventId, 99)
    }

    func test_pollAttempt_timeout_throws() async {
        let mock = MockHTTPClient()
        let map = makeMap(token: "cat_abc", status: .open, eventId: 1)
        mock.enqueueRepeating(map)
        let schedule = PollingSchedule(intervals: [0.01, 0.01], totalBudget: 0.05)
        let poller = SessionPoller(
            httpClient: mock,
            sessionToken: sessionToken,
            checkoutAttemptToken: "cat_abc",
            schedule: schedule
        )
        do {
            for try await _ in poller.pollAttempt() {}
            XCTFail("Expected MollieError.timeout")
        } catch let MollieError.timeout(operation) {
            XCTAssertEqual(operation, "checkout-attempt-polling")
        } catch {
            XCTFail("Expected MollieError.timeout but got \(error)")
        }
    }

    func test_pollAttempt_cancellation_stopsImmediately() async throws {
        let mock = MockHTTPClient()
        let map = makeMap(token: "cat_abc", status: .open, eventId: 1)
        mock.enqueueRepeating(map)
        let schedule = PollingSchedule(intervals: Array(repeating: 1.0, count: 50), totalBudget: 60)
        let poller = SessionPoller(
            httpClient: mock,
            sessionToken: sessionToken,
            checkoutAttemptToken: "cat_abc",
            schedule: schedule
        )
        let task = Task {
            var count = 0
            for try await _ in poller.pollAttempt() {
                count += 1
            }
            return count
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        task.cancel()
        let countAtCancel = mock.callCount
        _ = await task.result
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertLessThanOrEqual(mock.callCount, countAtCancel + 1)
    }

    func test_pollAttempt_timesOut_emitsTimeoutAndThrows() async {
        // Parity with `test_poll_timeoutExceeded_throwsMollieError`: when the
        // backend never returns the requested token within the budget, the
        // attempt-polling path must throw `.timeout(operation: "checkout-attempt-polling")`
        // — not silently hang.
        let mock = MockHTTPClient()
        // All polls return an empty map → continuous transient misses → budget exhausted.
        mock.enqueueRepeating(CheckoutAttemptsStateMap())
        let schedule = PollingSchedule(intervals: [0.01, 0.01, 0.01], totalBudget: 0.05)
        let poller = SessionPoller(
            httpClient: mock,
            sessionToken: sessionToken,
            checkoutAttemptToken: "cat_never_appears",
            schedule: schedule
        )

        do {
            for try await _ in poller.pollAttempt() {}
            XCTFail("Expected MollieError.timeout to be thrown")
        } catch let MollieError.timeout(operation) {
            XCTAssertEqual(operation, "checkout-attempt-polling")
        } catch {
            XCTFail("Expected MollieError.timeout but got \(error)")
        }
    }

    func test_pollAttempt_transientMiss_doesNotAdvanceBackoff() async throws {
        // Regression: when `map[token]` is nil the poller must NOT advance
        // the backoff index — three consecutive misses should keep the sleep
        // at intervals[0], not intervals[3]. We measure this by recording
        // call timestamps and asserting all inter-poll gaps are within the
        // intervals[0] cadence (well below intervals[3]).
        let mock = MockHTTPClient()
        // 3 misses, then a hit so we can terminate cleanly.
        mock.enqueue(CheckoutAttemptsStateMap())
        mock.enqueue(CheckoutAttemptsStateMap())
        mock.enqueue(CheckoutAttemptsStateMap())
        mock.enqueue(makeMap(token: "cat_abc", status: .completed, eventId: 1))
        // Steeply escalating intervals with a near-zero intervals[0]. If the
        // index stays pinned, the three misses sleep ~0s and elapsed is just
        // test overhead. If the index advances, the second/third miss sleep
        // 1.0s + 2.0s, so elapsed jumps to seconds — a multi-second gap that
        // discriminates robustly even on a loaded CI runner (the old
        // 0.06s-vs-0.32s spread was within scheduler-jitter range and flaked).
        let schedule = PollingSchedule(
            intervals: [0.01, 1.0, 2.0, 4.0, 8.0],
            totalBudget: 20.0
        )
        let poller = SessionPoller(
            httpClient: mock,
            sessionToken: sessionToken,
            checkoutAttemptToken: "cat_abc",
            schedule: schedule
        )
        let start = ContinuousClock.now
        for try await _ in poller.pollAttempt() {
            break
        }
        let elapsed = start.duration(to: .now)
        // Pinned to intervals[0] (0.01s) × 3 misses = ~0.03s + overhead.
        // If the backoff advanced, elapsed would be ≥ 1.0 + 2.0 = 3.0s.
        // The 0.5s threshold sits far above worst-case CI overhead yet far
        // below the advanced-index floor — a ~6× margin either way.
        XCTAssertLessThan(elapsed, .milliseconds(500),
                          "Transient misses must not advance the backoff index")
    }

    /// `.skipNoAdvance` outcomes must be bounded by
    /// `maxConsecutiveNoAdvanceRetries`. Without the cap, an `.infinity`
    /// totalBudget (the new default for hosts that supply their own cancel
    /// control) would let `pollAttempt()` busy-loop forever when the backend
    /// never populates the per-attempt state — strands the SDK with no way
    /// for the host UI to surface the failure.
    func test_pollAttempt_skipNoAdvance_capsAtMaxRetries() async {
        // Enqueue (cap + 1) empty maps so the loop trips the cap on iteration
        // (cap + 1). `enqueueRepeating` lets us avoid hand-listing every
        // entry while still asserting the failure surfaces.
        let mock = MockHTTPClient()
        mock.enqueueRepeating(CheckoutAttemptsStateMap())
        // Infinite budget so only the no-advance cap can terminate the loop —
        // matches the production "host owns cancellation" wiring.
        let schedule = PollingSchedule(
            intervals: [0.001],
            totalBudget: .infinity
        )
        let poller = SessionPoller(
            httpClient: mock,
            sessionToken: sessionToken,
            checkoutAttemptToken: "cat_never_populated",
            schedule: schedule
        )

        do {
            for try await _ in poller.pollAttempt() {}
            XCTFail("Expected MollieError.timeout to be thrown when no-advance cap is exceeded")
        } catch let MollieError.timeout(operation) {
            // Stable reason — DevTools timeline + caller mapping rely on
            // distinguishing "stuck checkout-attempt" from generic polling
            // timeout.
            XCTAssertEqual(operation, "checkout-attempt-stuck")
        } catch {
            XCTFail("Expected MollieError.timeout but got \(error)")
        }

        // Sanity: callCount must be at least cap + 1 (initial + cap retries
        // before bail), proving the cap actually kicked in rather than some
        // other timeout path firing first.
        XCTAssertGreaterThan(mock.callCount, SessionPoller.maxConsecutiveNoAdvanceRetries)
    }

    func test_pollAttempt_withoutCheckoutAttemptToken_throwsInvalidConfiguration() async {
        let mock = MockHTTPClient()
        // Poller built without checkoutAttemptToken — should immediately throw.
        let poller = SessionPoller(httpClient: mock, sessionToken: sessionToken, schedule: makeFastSchedule())
        do {
            for try await _ in poller.pollAttempt() {}
            XCTFail("Expected invalidConfiguration error")
        } catch let MollieError.invalidConfiguration(field, _) {
            XCTAssertEqual(field, "checkoutAttemptToken")
        } catch {
            XCTFail("Expected MollieError.invalidConfiguration but got \(error)")
        }
    }

    // MARK: - Error propagation

    // MARK: - debug emit-site

    func test_poll_httpError_propagates() async {
        let mock = MockHTTPClient()
        mock.enqueue(error: MollieError.api(.unauthorized))
        let poller = SessionPoller(httpClient: mock, sessionToken: sessionToken, schedule: makeFastSchedule())

        do {
            _ = try await collect(from: poller.poll())
            XCTFail("Expected MollieError.api(.unauthorized) to be thrown")
        } catch MollieError.api(.unauthorized) {
            // expected
        } catch {
            XCTFail("Expected MollieError.api(.unauthorized) but got \(error)")
        }
    }

    // MARK: - Transient fetch-failure resilience

    func test_poll_singleTransientFetchError_continuesToTerminal() async throws {
        // Bug caught: pre-fix, ANY fetch throw inside runPollLoop called
        // continuation.finish(throwing:) and ended the stream — so one
        // transient network blip killed polling and surfaced an error even
        // though the payment was still resolving. A single retryable URLError
        // mid-stream must be absorbed; polling must continue to a terminal state.
        let mock = MockHTTPClient()
        mock.enqueue(makeResponse(status: .open)) // initial poll succeeds
        mock.enqueue(error: MollieError.network(URLError(.networkConnectionLost))) // transient blip
        mock.enqueue(makeResponse(status: .completed)) // recovers → terminal
        let poller = SessionPoller(httpClient: mock, sessionToken: sessionToken, schedule: makeFastSchedule())

        let results = try await collect(from: poller.poll())

        // The blip is absorbed (no yield for it); polling reaches .completed.
        XCTAssertEqual(results.map(\.status), [.known(.open), .known(.completed)])
    }

    func test_poll_singleTransientServerError_continuesToTerminal() async throws {
        // Bug caught: a single 5xx (transient server error) must not kill the
        // stream — it should be retried within budget, same as a URLError blip.
        let mock = MockHTTPClient()
        mock.enqueue(makeResponse(status: .open))
        mock.enqueue(error: MollieError.api(.serverError(503)))
        mock.enqueue(makeResponse(status: .completed))
        let poller = SessionPoller(httpClient: mock, sessionToken: sessionToken, schedule: makeFastSchedule())

        let results = try await collect(from: poller.poll())

        XCTAssertEqual(results.map(\.status), [.known(.open), .known(.completed)])
    }

    func test_poll_consecutiveTransientErrorsOverCap_surfacesError() async {
        // Bug caught: the consecutive-failure counter must be BOUNDED. Without
        // a cap, an .infinity budget + a backend that always throws transiently
        // would spin forever. Over the cap, the loop must give up and surface
        // an error (the last one) rather than continue indefinitely.
        let mock = MockHTTPClient()
        mock.enqueue(makeResponse(status: .open)) // initial poll succeeds → enter loop
        mock.enqueueRepeating(error: MollieError.network(URLError(.timedOut)))
        // Infinite budget so ONLY the failure cap can terminate the loop.
        let schedule = PollingSchedule(intervals: [0.001], totalBudget: .infinity)
        let poller = SessionPoller(httpClient: mock, sessionToken: sessionToken, schedule: schedule)

        do {
            _ = try await collect(from: poller.poll())
            XCTFail("Expected an error once the consecutive-failure cap is exceeded")
        } catch let MollieError.network(urlError) {
            // Last error surfaced after the cap.
            XCTAssertEqual(urlError.code, .timedOut)
        } catch let MollieError.timeout(operation) {
            // Also acceptable: timeout reason on cap exhaustion.
            XCTAssertEqual(operation, "session-polling")
        } catch {
            XCTFail("Expected the last transient error or .timeout, got \(error)")
        }
        // Cap must have actually engaged: initial + > cap retries.
        XCTAssertGreaterThan(mock.callCount, SessionPoller.maxConsecutiveFetchFailures)
    }

    func test_poll_transientFailureCounterResetsOnSuccess() async throws {
        // Bug caught: the counter must RESET on a successful fetch. A few blips,
        // a recovery, then more blips must not accumulate across the recovery —
        // otherwise a long-lived poll with sporadic blips would eventually trip
        // the cap even though it never had `cap` failures back-to-back.
        let mock = MockHTTPClient()
        mock.enqueue(makeResponse(status: .open)) // initial
        // Burst 1 of failures (under cap), then a success that must reset.
        mock.enqueue(error: MollieError.network(URLError(.networkConnectionLost)))
        mock.enqueue(error: MollieError.network(URLError(.networkConnectionLost)))
        mock.enqueue(makeResponse(status: .open)) // recovery — resets counter
        // Burst 2 of failures (under cap again), then terminal.
        mock.enqueue(error: MollieError.network(URLError(.networkConnectionLost)))
        mock.enqueue(error: MollieError.network(URLError(.networkConnectionLost)))
        mock.enqueue(makeResponse(status: .completed))
        let poller = SessionPoller(httpClient: mock, sessionToken: sessionToken, schedule: makeFastSchedule())

        let results = try await collect(from: poller.poll())

        // Both bursts absorbed; reaches .completed without surfacing an error.
        XCTAssertEqual(results.map(\.status), [.known(.open), .known(.open), .known(.completed)])
    }

    func test_poll_terminalAuthErrorMidStream_propagatesImmediately() async {
        // Bug caught: a terminal/auth error (401) must NOT be retried — it's
        // not transient and the token will never become valid by re-polling.
        // It must propagate immediately, even mid-stream after a success.
        let mock = MockHTTPClient()
        mock.enqueue(makeResponse(status: .open)) // initial poll succeeds → loop
        mock.enqueue(error: MollieError.api(.unauthorized)) // terminal → propagate now
        mock.enqueue(makeResponse(status: .completed)) // must NEVER be reached
        let poller = SessionPoller(httpClient: mock, sessionToken: sessionToken, schedule: makeFastSchedule())

        do {
            _ = try await collect(from: poller.poll())
            XCTFail("Expected MollieError.api(.unauthorized) to propagate immediately")
        } catch MollieError.api(.unauthorized) {
            // expected
        } catch {
            XCTFail("Expected MollieError.api(.unauthorized) but got \(error)")
        }
        // The post-error response must not have been consumed.
        XCTAssertEqual(mock.callCount, 2)
    }

    func test_poll_terminalForbiddenError_propagatesImmediately() async {
        // 403 is a configuration error — refreshing/retrying never helps.
        let mock = MockHTTPClient()
        mock.enqueue(error: MollieError.api(.forbidden))
        let poller = SessionPoller(httpClient: mock, sessionToken: sessionToken, schedule: makeFastSchedule())

        do {
            _ = try await collect(from: poller.poll())
            XCTFail("Expected MollieError.api(.forbidden) to propagate")
        } catch MollieError.api(.forbidden) {
            // expected
        } catch {
            XCTFail("Expected MollieError.api(.forbidden) but got \(error)")
        }
    }

    func test_poll_terminalValidationError_propagatesImmediately() async {
        // 422 validation is a terminal client error — not retryable.
        let mock = MockHTTPClient()
        mock.enqueue(makeResponse(status: .open))
        mock.enqueue(error: MollieError.api(.validationFailed([])))
        let poller = SessionPoller(httpClient: mock, sessionToken: sessionToken, schedule: makeFastSchedule())

        do {
            _ = try await collect(from: poller.poll())
            XCTFail("Expected MollieError.api(.validationFailed) to propagate")
        } catch MollieError.api(.validationFailed) {
            // expected
        } catch {
            XCTFail("Expected MollieError.api(.validationFailed) but got \(error)")
        }
    }

    func test_poll_non5xxServerErrorMidStream_propagatesImmediately() async {
        // Acceptance finding: isTransientFetchError matched `.serverError` with
        // NO code bound, so an odd 4xx (418/499) or 600+ — which validate()'s
        // default arm maps to `.serverError(code)` — was absorbed mid-poll and
        // burned the budget. RetryPolicy only treats 500...599 as transient;
        // the poller must match. A persistent 418 is terminal: propagate now,
        // do NOT absorb-and-retry.
        let mock = MockHTTPClient()
        mock.enqueue(makeResponse(status: .open)) // initial poll succeeds → loop
        mock.enqueue(error: MollieError.api(.serverError(418))) // out-of-band → terminal
        mock.enqueue(makeResponse(status: .completed)) // must NEVER be reached
        let poller = SessionPoller(httpClient: mock, sessionToken: sessionToken, schedule: makeFastSchedule())

        do {
            _ = try await collect(from: poller.poll())
            XCTFail("Expected MollieError.api(.serverError(418)) to propagate immediately")
        } catch MollieError.api(.serverError(418)) {
            // expected
        } catch {
            XCTFail("Expected .serverError(418) but got \(error)")
        }
        // The post-error response must not have been consumed.
        XCTAssertEqual(mock.callCount, 2)
    }

    func test_poll_serverError499MidStream_propagatesImmediately() async {
        // 499 is below the 500...599 bound — terminal, must not be absorbed.
        let mock = MockHTTPClient()
        mock.enqueue(makeResponse(status: .open))
        mock.enqueue(error: MollieError.api(.serverError(499)))
        mock.enqueue(makeResponse(status: .completed))
        let poller = SessionPoller(httpClient: mock, sessionToken: sessionToken, schedule: makeFastSchedule())

        do {
            _ = try await collect(from: poller.poll())
            XCTFail("Expected MollieError.api(.serverError(499)) to propagate immediately")
        } catch MollieError.api(.serverError(499)) {
            // expected
        } catch {
            XCTFail("Expected .serverError(499) but got \(error)")
        }
        XCTAssertEqual(mock.callCount, 2)
    }

    func test_poll_5xxServerError_stillAbsorbedAndRetried() async throws {
        // Regression guard: the in-band 500...599 case must STAY transient —
        // a 503 mid-stream is still absorbed and polling continues to terminal
        // (existing behaviour preserved by the bound).
        let mock = MockHTTPClient()
        mock.enqueue(makeResponse(status: .open))
        mock.enqueue(error: MollieError.api(.serverError(503)))
        mock.enqueue(makeResponse(status: .completed))
        let poller = SessionPoller(httpClient: mock, sessionToken: sessionToken, schedule: makeFastSchedule())

        let results = try await collect(from: poller.poll())

        XCTAssertEqual(results.map(\.status), [.known(.open), .known(.completed)])
    }

    func test_poll_initialPollTransientError_continuesToTerminal() async throws {
        // Bug caught: the FIRST fetch site (initial poll, no leading sleep) was
        // a separate try/catch that also finished the stream on any throw. A
        // transient error on the very first poll must be absorbed too.
        let mock = MockHTTPClient()
        mock.enqueue(error: MollieError.network(URLError(.networkConnectionLost))) // initial blip
        mock.enqueue(makeResponse(status: .completed)) // recovery → terminal
        let poller = SessionPoller(httpClient: mock, sessionToken: sessionToken, schedule: makeFastSchedule())

        let results = try await collect(from: poller.poll())

        XCTAssertEqual(results.map(\.status), [.known(.completed)])
    }
}
