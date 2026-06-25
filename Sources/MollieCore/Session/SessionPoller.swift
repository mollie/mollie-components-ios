import Foundation

/// Polls the Sessions Service for a session's status until it reaches a
/// terminal state (`.completed` or `.expired`), the cumulative time budget
/// is exhausted, the parent task is cancelled, or an HTTP error is thrown.
///
/// Each poll emits the latest `SessionResponse` on the returned stream so
/// callers can react to intermediate updates (e.g. `nextAction` changes
/// while status remains `.open`).
package final class SessionPoller: Sendable {
    private let httpClient: any HTTPClient
    private let sessionToken: String
    private let checkoutAttemptToken: String?
    private let schedule: PollingSchedule

    package init(
        httpClient: any HTTPClient,
        sessionToken: String,
        schedule: PollingSchedule = .default
    ) {
        self.httpClient = httpClient
        self.sessionToken = sessionToken
        checkoutAttemptToken = nil
        self.schedule = schedule
    }

    package init(
        httpClient: any HTTPClient,
        sessionToken: String,
        checkoutAttemptToken: String,
        schedule: PollingSchedule = .default
    ) {
        self.httpClient = httpClient
        self.sessionToken = sessionToken
        self.checkoutAttemptToken = checkoutAttemptToken
        self.schedule = schedule
    }

    package func poll() -> AsyncThrowingStream<SessionResponse, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [httpClient, sessionToken, schedule] in
                await Self.runPollLoop(
                    schedule: schedule,
                    timeoutOperation: "session-polling",
                    continuation: continuation,
                    fetch: {
                        try await httpClient.perform(SessionEndpoint.get(sessionToken: sessionToken))
                    },
                    process: { response in
                        if case let .known(status) = response.status, status == .completed || status == .expired {
                            return .yieldTerminal(response)
                        }
                        return .yield(response)
                    }
                )
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Polls `GET /checkout-attempts/` and yields the per-attempt `SessionResponse`
    /// whenever `nextAction.eventId` changes. Missing tokens are treated as transient
    /// (does NOT advance the backoff index — see PollOutcome.skipNoAdvance).
    /// Terminates on stream cancellation or budget exhaustion; terminal semantics are
    /// determined by the consumer.
    package func pollAttempt() -> AsyncThrowingStream<SessionResponse, Error> {
        guard let checkoutAttemptToken else {
            return AsyncThrowingStream { continuation in
                continuation.finish(
                    throwing: MollieError.invalidConfiguration(
                        field: "checkoutAttemptToken",
                        reason: "pollAttempt() requires a checkoutAttemptToken — use init(httpClient:sessionToken:checkoutAttemptToken:)"
                    )
                )
            }
        }
        return AsyncThrowingStream { [httpClient, sessionToken, schedule] continuation in
            let token = checkoutAttemptToken
            let task = Task {
                // Mutable state local to this poll loop.
                var hasYieldedFirst = false
                var lastEventId: Int?
                await Self.runPollLoop(
                    schedule: schedule,
                    timeoutOperation: "checkout-attempt-polling",
                    continuation: continuation,
                    fetch: {
                        try await httpClient.perform(
                            SessionEndpoint.getCheckoutAttempts(sessionToken: sessionToken)
                        )
                    },
                    process: { map -> PollOutcome<SessionResponse> in
                        guard let response = map[token] else {
                            // Transient miss: backend hasn't created the per-attempt
                            // state for this token yet. Do NOT advance the backoff
                            // index — re-poll at the current cadence.
                            return .skipNoAdvance
                        }
                        let newEventId = response.nextAction.eventId
                        // Only deduplicate when both old and new eventId are non-nil and equal.
                        // nil eventId means the server has not assigned an event yet — always yield.
                        let isDuplicate = hasYieldedFirst && newEventId != nil && newEventId == lastEventId
                        if isDuplicate {
                            return .skipAdvance
                        }
                        hasYieldedFirst = true
                        lastEventId = newEventId
                        return .yield(response)
                    }
                )
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Shared poll loop

    /// Maximum number of consecutive `.skipNoAdvance` outcomes before the
    /// poll loop bails out with a timeout. Required because `.skipNoAdvance`
    /// holds the backoff at `intervals[0]` indefinitely; with
    /// `pollingTimeoutSeconds = .infinity` this would otherwise busy-loop
    /// forever. 50 retries at the smallest production interval (0.5s) yields
    /// roughly 25 seconds — long enough to absorb genuine "backend hasn't
    /// populated state yet" transients without giving up on a slow create.
    package static let maxConsecutiveNoAdvanceRetries = 50

    /// Maximum number of consecutive transient *fetch* failures (retryable
    /// `URLError` or `5xx` server error) the poll loop will absorb before
    /// giving up and surfacing the last error. Mirrors
    /// `maxConsecutiveNoAdvanceRetries`: a single transient blip must not kill
    /// polling (the payment may still be resolving), but an unbounded run —
    /// especially under an `.infinity` budget — must still terminate rather
    /// than retry forever. Reset to 0 on every successful fetch.
    package static let maxConsecutiveFetchFailures = 50

    /// Classifies a thrown fetch error as transient (worth absorbing and
    /// re-polling) vs terminal (propagate immediately). Transient = a
    /// retryable transport `URLError` (mirrors `RetryPolicy`'s retryable set)
    /// or a `5xx` `MollieError.api(.serverError)`. Everything else — auth
    /// (401/403), validation (422), and any non-retryable URLError — is
    /// terminal and must surface to the caller without further polling.
    private static func isTransientFetchError(_ error: Error) -> Bool {
        // Retryable transport codes — same set as RetryPolicy.shouldRetry.
        let retryableURLErrorCodes: Set<URLError.Code> = [
            .timedOut, .cannotFindHost, .cannotConnectToHost,
            .networkConnectionLost, .notConnectedToInternet,
        ]
        if let urlError = error as? URLError {
            return retryableURLErrorCodes.contains(urlError.code)
        }
        switch error {
        case let MollieError.network(urlError):
            return retryableURLErrorCodes.contains(urlError.code)
        case let MollieError.api(.serverError(code)):
            // Bound to 5xx — must match RetryPolicy.isRetryable exactly.
            // validate()'s default arm maps odd 4xx (418/499) and 600+ to
            // .serverError(code); those are NOT transient and must propagate
            // immediately rather than be absorbed and burn the poll budget.
            return (500 ... 599).contains(code)
        default:
            return false
        }
    }

    /// Outcome returned by `process` for a single fetch.
    private enum PollOutcome<Yielded> {
        /// Yield this value and continue polling at the next backoff step.
        case yield(Yielded)
        /// Yield this value and finish the stream — terminal state observed.
        case yieldTerminal(Yielded)
        /// Discard this fetch, advance the backoff index, keep polling.
        case skipAdvance
        /// Discard this fetch, do NOT advance the backoff index, keep polling.
        /// Used for transient misses (e.g. backend hasn't populated state yet).
        case skipNoAdvance
    }

    // swiftlint:disable cyclomatic_complexity
    /// Drives the shared poll cadence: initial poll → (sleep → cancel-check →
    /// timeout-check → fetch → process)*. Yields onto `continuation`.
    /// Uses `ContinuousClock` for the timeout (suspension-safe; iOS 16+).
    /// The cyclomatic count is intrinsic to the state machine (init/loop ×
    /// fetch/sleep/cancel/timeout × outcome); splitting further fragments
    /// the cancellation/timeout contract without reducing real complexity.
    private static func runPollLoop<Yielded, Response>(
        schedule: PollingSchedule,
        timeoutOperation: String,
        continuation: AsyncThrowingStream<Yielded, Error>.Continuation,
        fetch: () async throws -> Response,
        process: (Response) -> PollOutcome<Yielded>
    ) async {
        let start = ContinuousClock.now
        if Task.isCancelled {
            continuation.finish()
            return
        }
        // Consecutive transient *fetch* failures (retryable URLError / 5xx).
        // A single transient blip must not end the stream — increment and
        // keep polling; reset on a successful fetch. Bounded by
        // `maxConsecutiveFetchFailures` so an `.infinity` budget cannot retry
        // forever. Terminal/auth errors bypass this and propagate at once.
        var consecutiveFetchFailures = 0
        // Initial poll — no leading sleep.
        do {
            let firstResponse = try await fetch()
            switch process(firstResponse) {
            case let .yield(value):
                continuation.yield(value)
            case let .yieldTerminal(value):
                continuation.yield(value)
                continuation.finish()
                return
            case .skipAdvance, .skipNoAdvance:
                break
            }
        } catch {
            // Terminal/auth → propagate immediately. Transient → fall through
            // into the loop (which sleeps then re-fetches); no yield for the
            // failed poll. Cap is checked on subsequent loop failures.
            guard Self.isTransientFetchError(error) else {
                continuation.finish(throwing: error)
                return
            }
            consecutiveFetchFailures += 1
        }

        var index = 0
        // Consecutive `.skipNoAdvance` outcomes — bounded by
        // `maxConsecutiveNoAdvanceRetries` so the loop cannot busy-spin when
        // `totalBudget` is `.infinity` and the backend never populates the
        // per-attempt state. Reset on every non-skip-noadvance outcome.
        var consecutiveNoAdvance = 0
        while !Task.isCancelled {
            let interval = schedule.intervals[min(index, schedule.intervals.count - 1)]
            do {
                try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            } catch {
                continuation.finish()
                return
            }
            if Task.isCancelled {
                continuation.finish()
                return
            }
            // `.infinity` (or any non-finite value) disables the timeout —
            // skip the comparison entirely. `Duration.seconds(.infinity)`
            // overflows the internal Int128 representation and triggers a
            // fatalError, which `try?` cannot catch.
            // swiftlint:disable opening_brace
            if schedule.totalBudget.isFinite,
               start.duration(to: .now) > .seconds(schedule.totalBudget)
            {
                continuation.finish(throwing: MollieError.timeout(operation: timeoutOperation))
                return
            }
            // swiftlint:enable opening_brace
            let response: Response
            do {
                response = try await fetch()
            } catch {
                // Terminal/auth → propagate immediately (no retry). Transient
                // (retryable URLError / 5xx) → absorb and keep polling while
                // under the cap; on cap exhaustion surface the last error.
                guard Self.isTransientFetchError(error) else {
                    continuation.finish(throwing: error)
                    return
                }
                consecutiveFetchFailures += 1
                if consecutiveFetchFailures > Self.maxConsecutiveFetchFailures {
                    continuation.finish(throwing: error)
                    return
                }
                index += 1
                continue
            }
            // Successful fetch — reset the transient-failure counter.
            consecutiveFetchFailures = 0
            switch process(response) {
            case let .yield(value):
                continuation.yield(value)
                index += 1
                consecutiveNoAdvance = 0
            case let .yieldTerminal(value):
                continuation.yield(value)
                continuation.finish()
                return
            case .skipAdvance:
                index += 1
                consecutiveNoAdvance = 0
            case .skipNoAdvance:
                // Transient miss: hold backoff at the current step.
                consecutiveNoAdvance += 1
                if consecutiveNoAdvance > Self.maxConsecutiveNoAdvanceRetries {
                    // Backend never populated the per-attempt state — fail
                    // with a stable timeout reason so the consumer can map
                    // it to `.sessionFailed`. Without this cap, infinite
                    // `totalBudget` would spin here forever.
                    continuation.finish(throwing: MollieError.timeout(operation: "checkout-attempt-stuck"))
                    return
                }
                continue
            }
        }
        continuation.finish()
    }
    // swiftlint:enable cyclomatic_complexity
}

/// Renders a `ParsedEnum<SessionStatus>` as the string the DevTools timeline
/// displays. Kept fileprivate — this is purely an emit-site concern.
private func statusString(_ status: ParsedEnum<SessionStatus>) -> String {
    switch status {
    case let .known(value): value.rawValue
    case let .unknown(raw): raw
    }
}
