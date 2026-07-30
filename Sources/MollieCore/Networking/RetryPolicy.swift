import Foundation

public struct RetryPolicy {
    public let maxAttempts: Int
    public let baseDelay: TimeInterval

    /// Returns a value within the given range. Injected so jitter is
    /// deterministic in tests; defaults to a uniform random draw.
    private let randomFactor: (ClosedRange<Double>) -> Double

    public static let `default` = RetryPolicy(maxAttempts: 3, baseDelay: 0.5)

    /// Upper bound (seconds) for an honoured `Retry-After`. A server can send a
    /// negative value (which `Int.init` parses verbatim → would trap on the
    /// `UInt64(delay * 1e9)` conversion) or a huge one (minutes/hours → an
    /// unbounded `Task.sleep`). Both are clamped into `[0, maxRetryAfter]`.
    /// 30s is deliberately small: this is an interactive card payment — the
    /// cardholder is waiting, so we never block them for minutes even if the
    /// server asks us to.
    public static let maxRetryAfter: TimeInterval = 30

    public init(
        maxAttempts: Int,
        baseDelay: TimeInterval,
        randomFactor: @escaping (ClosedRange<Double>) -> Double = { Double.random(in: $0) }
    ) {
        self.maxAttempts = maxAttempts
        self.baseDelay = baseDelay
        self.randomFactor = randomFactor
    }

    /// Whether an error should be retried on the given attempt.
    ///
    /// Retries are gated on `isIdempotent` — charging POST/PATCH are never
    /// auto-retried (no server-honoured dedup exists; Model B).
    /// For idempotent ops we retry transient URLErrors plus HTTP failures the
    /// server has already classified as transient: `5xx`, `429`, and `409`.
    public func shouldRetry(attempt: Int, error: Error, isIdempotent: Bool) -> Bool {
        guard isIdempotent, attempt < maxAttempts else { return false }

        if let urlError = error as? URLError {
            let retryableCodes: Set<URLError.Code> = [
                .timedOut, .cannotFindHost, .cannotConnectToHost,
                .networkConnectionLost, .notConnectedToInternet,
            ]
            return retryableCodes.contains(urlError.code)
        }

        if case let .api(apiError) = error as? MollieError {
            return isRetryable(apiError)
        }

        return false
    }

    /// The exponential backoff base for an attempt, before jitter.
    private func backoffBase(for attempt: Int) -> TimeInterval {
        baseDelay * pow(2.0, Double(attempt))
    }

    /// Jittered backoff delay. Full jitter: a uniform draw in
    /// `[0, exponentialBase]` so simultaneously-failing clients spread out
    /// instead of retrying in lockstep (thundering herd).
    public func delay(for attempt: Int) -> TimeInterval {
        let ceiling = backoffBase(for: attempt)
        guard ceiling > 0 else { return 0 }
        return randomFactor(0 ... ceiling)
    }

    /// The wait to honour before the next attempt. When the error carries a
    /// `Retry-After` (parsed into `.rateLimited`/`.conflict`) that header wins;
    /// otherwise fall back to the jittered exponential backoff.
    public func effectiveDelay(for attempt: Int, error: Error) -> TimeInterval {
        if let retryAfter = retryAfterSeconds(from: error) {
            // Clamp into [0, maxRetryAfter]: a negative Retry-After becomes 0
            // (never negative — `UInt64(negative)` traps), and a huge value is
            // capped so an interactive payment never sleeps for minutes.
            return min(max(0, TimeInterval(retryAfter)), Self.maxRetryAfter)
        }
        return delay(for: attempt)
    }

    private func isRetryable(_ apiError: MollieError.APIError) -> Bool {
        switch apiError {
        case .rateLimited, .conflict:
            true
        case let .serverError(code):
            (500 ... 599).contains(code)
        case .unauthorized, .forbidden, .notFound, .validationFailed:
            false
        }
    }

    private func retryAfterSeconds(from error: Error) -> Int? {
        guard case let .api(apiError) = error as? MollieError else { return nil }
        switch apiError {
        case let .rateLimited(retryAfter), let .conflict(retryAfter):
            return retryAfter
        default:
            return nil
        }
    }
}
