import Foundation

public final class SessionClient: HTTPClient, @unchecked Sendable {
    private let baseURL: URL
    private let clientAccessToken: String
    private let retryPolicy: RetryPolicy
    private let session: URLSession

    public init(
        baseURL: URL,
        clientAccessToken: String,
        retryPolicy: RetryPolicy = .default,
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.clientAccessToken = clientAccessToken
        self.retryPolicy = retryPolicy
        self.session = session
    }

    public func perform<T: Decodable>(_ endpoint: Endpoint<T>) async throws -> T {
        let request = try endpoint.asURLRequest(baseURL: baseURL, clientAccessToken: clientAccessToken)
        return try await execute(request: request, endpoint: endpoint, attempt: 0)
    }

    private func execute<T: Decodable>(
        request: URLRequest,
        endpoint: Endpoint<T>,
        attempt: Int
    ) async throws -> T {
        MollieLogger.log("SessionClient", "→ \(request.httpMethod ?? "?") \(request.url?.absoluteString ?? "?")")
        // Do not log request body — session payloads may include cardholder / session token data.
        do {
            let (data, response) = try await session.data(for: request)
            // URLSession guarantees HTTP responses are HTTPURLResponse
            let httpResponse = response as! HTTPURLResponse // swiftlint:disable:this force_cast
            MollieLogger.log("SessionClient", "← HTTP \(httpResponse.statusCode)")
            // Do not log response body — may include session tokens / sensitive details.
            try validate(httpResponse, data: data)
            return try MollieJSONDecoder().decode(T.self, from: data)
        } catch let error as MollieError {
            // Retry server-classified transient failures (5xx / 429 / 409) for
            // idempotent ops only, honouring any Retry-After. Charging POST/PATCH
            // are excluded via isIdempotent (spike #316, Model B).
            if try await retryIfPossible(error: error, request: request, endpoint: endpoint, attempt: attempt) {
                return try await execute(request: request, endpoint: endpoint, attempt: attempt + 1)
            }
            throw error
        } catch let error as URLError {
            if try await retryIfPossible(error: error, request: request, endpoint: endpoint, attempt: attempt) {
                return try await execute(request: request, endpoint: endpoint, attempt: attempt + 1)
            }
            throw MollieError.network(error)
        } catch {
            throw MollieError.unknown(error)
        }
    }

    /// Sleeps and returns `true` when `error` is retryable for this endpoint;
    /// returns `false` (no sleep) otherwise so the caller can rethrow.
    private func retryIfPossible(
        error: Error,
        request: URLRequest,
        endpoint: Endpoint<some Decodable>,
        attempt: Int
    ) async throws -> Bool {
        let isIdempotent = [HTTPMethod.get, .put, .delete].contains(endpoint.method)
        guard retryPolicy.shouldRetry(attempt: attempt, error: error, isIdempotent: isIdempotent) else {
            return false
        }
        // effectiveDelay is already clamped to [0, maxRetryAfter]; max(0, …)
        // here is belt-and-suspenders so a negative delay can never trap the
        // UInt64 conversion regardless of upstream changes.
        let nanoseconds = UInt64(max(0, retryPolicy.effectiveDelay(for: attempt, error: error)) * 1_000_000_000)
        try await Task.sleep(nanoseconds: nanoseconds)
        return true
    }

    private func validate(_ response: HTTPURLResponse, data: Data) throws {
        switch response.statusCode {
        case 200 ... 299:
            return
        case 401:
            throw MollieError.api(.unauthorized)
        case 403:
            throw MollieError.api(.forbidden)
        case 404:
            throw MollieError.api(.notFound)
        case 409:
            let retryAfter = response.value(forHTTPHeaderField: "Retry-After").flatMap(Int.init)
            throw MollieError.api(.conflict(retryAfter: retryAfter))
        case 429:
            let retryAfter = response.value(forHTTPHeaderField: "Retry-After").flatMap(Int.init)
            throw MollieError.api(.rateLimited(retryAfter: retryAfter))
        case 422:
            let violations = (try? JSONDecoder().decode(RFC7807Body.self, from: data))?.violations ?? []
            throw MollieError.api(.validationFailed(violations))
        default:
            throw MollieError.api(.serverError(response.statusCode))
        }
    }
}

private struct RFC7807Body: Decodable {
    let violations: [Violation]?
}
