import XCTest
@testable import MollieCore

final class RetryPolicyTests: XCTestCase {
    private let policy = RetryPolicy(maxAttempts: 3, baseDelay: 0.5)
    private let networkError = URLError(.notConnectedToInternet)

    func test_shouldRetry_true_whenIdempotentAndWithinAttempts() {
        XCTAssertTrue(policy.shouldRetry(attempt: 0, error: networkError, isIdempotent: true))
        XCTAssertTrue(policy.shouldRetry(attempt: 2, error: networkError, isIdempotent: true))
    }

    func test_shouldRetry_false_whenAttemptEqualsMaxAttempts() {
        XCTAssertFalse(policy.shouldRetry(attempt: 3, error: networkError, isIdempotent: true))
    }

    func test_shouldRetry_false_whenNonIdempotent() {
        XCTAssertFalse(policy.shouldRetry(attempt: 0, error: networkError, isIdempotent: false))
    }

    func test_shouldRetry_false_whenNonURLErrorAndNonAPIError() {
        // A token-validation error carries no transient signal — never retry.
        let mollieError = MollieError.invalidClientToken(reason: "bad")
        XCTAssertFalse(policy.shouldRetry(attempt: 0, error: mollieError, isIdempotent: true))
    }

    func test_shouldRetry_false_whenNonRetryableURLError() {
        XCTAssertFalse(policy.shouldRetry(attempt: 0, error: URLError(.cancelled), isIdempotent: true))
        XCTAssertFalse(policy.shouldRetry(attempt: 0, error: URLError(.userAuthenticationRequired), isIdempotent: true))
        XCTAssertFalse(policy.shouldRetry(attempt: 0, error: URLError(.unsupportedURL), isIdempotent: true))
    }

    // MARK: - MollieError classification (5xx / rateLimited / conflict)

    //
    // These pin the new behaviour: an HTTP error already classified into a
    // MollieError.api case must be retryable for idempotent ops only. Catches a
    // regression where shouldRetry inspects only URLError and silently drops a
    // retryable 503/429/409 (the duplicate-symptom of "ignores Retry-After").

    func test_shouldRetry_true_whenServerError5xxAndIdempotent() {
        // 5xx is transient on an idempotent op → retry.
        XCTAssertTrue(policy.shouldRetry(attempt: 0, error: MollieError.api(.serverError(503)), isIdempotent: true))
        XCTAssertTrue(policy.shouldRetry(attempt: 0, error: MollieError.api(.serverError(500)), isIdempotent: true))
        XCTAssertTrue(policy.shouldRetry(attempt: 0, error: MollieError.api(.serverError(502)), isIdempotent: true))
    }

    func test_shouldRetry_false_whenServerError5xxAndNonIdempotent() {
        // The charging-POST guard: a 5xx on POST/PATCH must NEVER auto-retry,
        // since there is no server-honoured dedup (Model B).
        XCTAssertFalse(policy.shouldRetry(attempt: 0, error: MollieError.api(.serverError(503)), isIdempotent: false))
    }

    func test_shouldRetry_false_whenServerError4xx() {
        // A non-5xx unexpected status routed to .serverError (e.g. an odd 4xx)
        // is an integration issue, not transient — do not retry even if idempotent.
        XCTAssertFalse(policy.shouldRetry(attempt: 0, error: MollieError.api(.serverError(418)), isIdempotent: true))
    }

    func test_shouldRetry_true_whenRateLimitedAndIdempotent() {
        XCTAssertTrue(policy.shouldRetry(
            attempt: 0,
            error: MollieError.api(.rateLimited(retryAfter: 2)),
            isIdempotent: true
        ))
        XCTAssertTrue(policy.shouldRetry(
            attempt: 0,
            error: MollieError.api(.rateLimited(retryAfter: nil)),
            isIdempotent: true
        ))
    }

    func test_shouldRetry_true_whenConflictAndIdempotent() {
        XCTAssertTrue(policy.shouldRetry(
            attempt: 0,
            error: MollieError.api(.conflict(retryAfter: 3)),
            isIdempotent: true
        ))
    }

    func test_shouldRetry_false_whenRateLimitedOrConflictAndNonIdempotent() {
        XCTAssertFalse(policy.shouldRetry(
            attempt: 0,
            error: MollieError.api(.rateLimited(retryAfter: 2)),
            isIdempotent: false
        ))
        XCTAssertFalse(policy.shouldRetry(
            attempt: 0,
            error: MollieError.api(.conflict(retryAfter: 3)),
            isIdempotent: false
        ))
    }

    func test_shouldRetry_false_whenNonRetryableAPIError() {
        // 401/403/404/422 are terminal classifications — never retry.
        XCTAssertFalse(policy.shouldRetry(attempt: 0, error: MollieError.api(.unauthorized), isIdempotent: true))
        XCTAssertFalse(policy.shouldRetry(attempt: 0, error: MollieError.api(.forbidden), isIdempotent: true))
        XCTAssertFalse(policy.shouldRetry(attempt: 0, error: MollieError.api(.notFound), isIdempotent: true))
        XCTAssertFalse(policy.shouldRetry(
            attempt: 0,
            error: MollieError.api(.validationFailed([])),
            isIdempotent: true
        ))
    }

    // MARK: - Jitter

    //
    // delay(for:) applies bounded (full) jitter around the exponential base so
    // that simultaneously-failing clients do not retry in lockstep (thundering
    // herd). Randomness is injected so tests are deterministic.

    func test_delay_withMaxRandom_equalsExponentialBase() {
        // Injected randomness that always returns the upper bound → the full
        // exponential base. This preserves the intent of the old exact-equality
        // delay test (0.5, 1.0, 2.0) as the jitter ceiling.
        let policy = RetryPolicy(maxAttempts: 3, baseDelay: 0.5, randomFactor: { $0.upperBound })
        XCTAssertEqual(policy.delay(for: 0), 0.5, accuracy: 0.001)
        XCTAssertEqual(policy.delay(for: 1), 1.0, accuracy: 0.001)
        XCTAssertEqual(policy.delay(for: 2), 2.0, accuracy: 0.001)
    }

    func test_delay_withMinRandom_isZero() {
        // Full jitter floor is 0.
        let policy = RetryPolicy(maxAttempts: 3, baseDelay: 0.5, randomFactor: { $0.lowerBound })
        XCTAssertEqual(policy.delay(for: 0), 0.0, accuracy: 0.001)
        XCTAssertEqual(policy.delay(for: 2), 0.0, accuracy: 0.001)
    }

    func test_delay_isWithinJitterBounds_forEachAttempt() {
        // With real randomness, every produced delay must fall within
        // [0, exponentialBase] for the attempt.
        let policy = RetryPolicy(maxAttempts: 5, baseDelay: 0.5)
        for attempt in 0 ..< 4 {
            let ceiling = 0.5 * pow(2.0, Double(attempt))
            for _ in 0 ..< 50 {
                let delay = policy.delay(for: attempt)
                XCTAssertGreaterThanOrEqual(delay, 0.0)
                XCTAssertLessThanOrEqual(delay, ceiling + 0.001)
            }
        }
    }

    func test_delay_isNotAlwaysIdentical() {
        // Guards against a no-op jitter (pure exponential): repeated calls for
        // the same attempt must not all collapse to a single value.
        let policy = RetryPolicy(maxAttempts: 5, baseDelay: 1.0)
        let samples = (0 ..< 50).map { _ in policy.delay(for: 3) }
        XCTAssertGreaterThan(Set(samples.map { ($0 * 1000).rounded() }).count, 1)
    }

    // MARK: - Retry-After consumption

    func test_effectiveDelay_honoursRetryAfter_overExponentialBackoff() {
        // An error carrying Retry-After drives the wait, not the jittered
        // exponential. Catches the bug where Retry-After is parsed but ignored.
        let policy = RetryPolicy(maxAttempts: 3, baseDelay: 0.5, randomFactor: { $0.upperBound })
        let rateLimited = MollieError.api(.rateLimited(retryAfter: 7))
        XCTAssertEqual(policy.effectiveDelay(for: 0, error: rateLimited), 7.0, accuracy: 0.001)
        let conflict = MollieError.api(.conflict(retryAfter: 4))
        XCTAssertEqual(policy.effectiveDelay(for: 2, error: conflict), 4.0, accuracy: 0.001)
    }

    func test_effectiveDelay_fallsBackToJitteredBackoff_whenNoRetryAfter() {
        // No Retry-After (nil header, 5xx, or URLError) → jittered exponential.
        let policy = RetryPolicy(maxAttempts: 3, baseDelay: 0.5, randomFactor: { $0.upperBound })
        XCTAssertEqual(policy.effectiveDelay(for: 1, error: MollieError.api(.serverError(503))), 1.0, accuracy: 0.001)
        XCTAssertEqual(
            policy.effectiveDelay(for: 1, error: MollieError.api(.rateLimited(retryAfter: nil))),
            1.0,
            accuracy: 0.001
        )
        XCTAssertEqual(policy.effectiveDelay(for: 0, error: URLError(.timedOut)), 0.5, accuracy: 0.001)
    }

    // MARK: - Retry-After clamping (acceptance finding: negative/huge → crash)

    //
    // `effectiveDelay` is consumed via `UInt64(delay * 1e9)` in the clients.
    // A negative `Retry-After` (e.g. the server sends "-5", which Int.init
    // parses verbatim) makes `UInt64(negativeDouble)` a FATAL TRAP, and a
    // huge value becomes an unbounded `Task.sleep`. Clamp to
    // `[0, maxRetryAfter]` so an interactive payment never crashes and never
    // sleeps for minutes.

    func test_effectiveDelay_negativeRetryAfter_clampedToNonNegative() {
        // A negative Retry-After must NOT produce a negative delay (which would
        // trap on UInt64 conversion). Clamp floor is 0.
        let policy = RetryPolicy(maxAttempts: 3, baseDelay: 0.5, randomFactor: { $0.upperBound })
        let rateLimited = MollieError.api(.rateLimited(retryAfter: -5))
        let delay = policy.effectiveDelay(for: 0, error: rateLimited)
        XCTAssertGreaterThanOrEqual(delay, 0.0)
        let conflict = MollieError.api(.conflict(retryAfter: -120))
        XCTAssertGreaterThanOrEqual(policy.effectiveDelay(for: 1, error: conflict), 0.0)
    }

    func test_effectiveDelay_hugeRetryAfter_clampedToCap() {
        // A huge Retry-After (minutes/hours) must be capped — an interactive
        // payment must not block the cardholder for that long.
        let policy = RetryPolicy(maxAttempts: 3, baseDelay: 0.5, randomFactor: { $0.upperBound })
        let rateLimited = MollieError.api(.rateLimited(retryAfter: 86400)) // 1 day
        let delay = policy.effectiveDelay(for: 0, error: rateLimited)
        XCTAssertEqual(delay, RetryPolicy.maxRetryAfter, accuracy: 0.001)
        XCTAssertLessThanOrEqual(delay, RetryPolicy.maxRetryAfter)
    }

    func test_effectiveDelay_zeroRetryAfter_isZero() {
        let policy = RetryPolicy(maxAttempts: 3, baseDelay: 0.5, randomFactor: { $0.upperBound })
        let delay = policy.effectiveDelay(for: 0, error: MollieError.api(.rateLimited(retryAfter: 0)))
        XCTAssertEqual(delay, 0.0, accuracy: 0.001)
    }

    func test_effectiveDelay_normalRetryAfterWithinCap_isHonoured() {
        // A sane value inside [0, cap] is passed through unchanged.
        let policy = RetryPolicy(maxAttempts: 3, baseDelay: 0.5, randomFactor: { $0.upperBound })
        let delay = policy.effectiveDelay(for: 0, error: MollieError.api(.conflict(retryAfter: 5)))
        XCTAssertEqual(delay, 5.0, accuracy: 0.001)
    }

    func test_maxRetryAfter_isBoundedForInteractivePayment() {
        // The cap must be a small interactive value, not minutes. Pins the
        // documented 30s bound so a future bump is a deliberate change.
        XCTAssertEqual(RetryPolicy.maxRetryAfter, 30.0, accuracy: 0.001)
    }
}
