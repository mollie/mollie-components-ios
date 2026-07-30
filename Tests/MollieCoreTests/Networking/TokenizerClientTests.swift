import XCTest
@testable import MollieCore

final class TokenizerClientTests: XCTestCase {
    private let baseURL = URL(string: "https://api.cc.mollie.com") ?? URL(fileURLWithPath: "/")
    private var capturedRequest: URLRequest?

    private func makeClient(retryPolicy: RetryPolicy = RetryPolicy(maxAttempts: 1, baseDelay: 0)) -> TokenizerClient {
        TokenizerClient(
            baseURL: baseURL,
            retryPolicy: retryPolicy,
            session: .makeMockSession()
        )
    }

    func test_perform_omitsAuthorizationHeader() async throws {
        MockURLProtocol.handler = { request in
            self.capturedRequest = request
            return (.make(statusCode: 200), Data(#"{"value":"tok","last4":"4242"}"#.utf8))
        }
        let client = makeClient()
        _ = try await client.perform(StubTokenEndpoint.lookup())
        XCTAssertNil(capturedRequest?.value(forHTTPHeaderField: "Authorization"))
    }

    func test_perform_appendsPathToBaseURL() async throws {
        MockURLProtocol.handler = { request in
            self.capturedRequest = request
            return (.make(statusCode: 200), Data(#"{"value":"tok","last4":"4242"}"#.utf8))
        }
        let client = makeClient()
        _ = try await client.perform(StubTokenEndpoint.lookup())
        XCTAssertEqual(capturedRequest?.url?.absoluteString, "https://api.cc.mollie.com/v1/card-tokens")
    }

    func test_perform_propagatesCustomHeadersToURLRequest() async throws {
        MockURLProtocol.handler = { request in
            self.capturedRequest = request
            return (.make(statusCode: 200), Data(#"{"value":"tok","last4":"4242"}"#.utf8))
        }
        let client = makeClient()
        _ = try await client.perform(StubTokenEndpoint.lookup(headers: ["X-Custom": "abc"]))
        XCTAssertEqual(capturedRequest?.value(forHTTPHeaderField: "X-Custom"), "abc")
    }

    func test_perform_422_throwsValidationFailed() async {
        MockURLProtocol.handler = { _ in
            let body = Data(#"{"violations":[{"name":"cardNumber","reason":"invalid"}]}"#.utf8)
            return (.make(statusCode: 422), body)
        }
        let client = makeClient()
        do {
            _ = try await client.perform(StubTokenEndpoint.lookup())
            XCTFail("Expected throw")
        } catch let MollieError.api(.validationFailed(violations)) {
            XCTAssertEqual(violations.count, 1)
            XCTAssertEqual(violations.first?.name, "cardNumber")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func test_perform_404_throwsNotFound() async {
        MockURLProtocol.handler = { _ in (.make(statusCode: 404), Data()) }
        let client = makeClient()
        do {
            _ = try await client.perform(StubTokenEndpoint.lookup())
            XCTFail("Expected throw")
        } catch MollieError.api(.notFound) {
            // ok
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func test_perform_serverError_throwsServerError() async {
        MockURLProtocol.handler = { _ in (.make(statusCode: 503), Data()) }
        let client = makeClient()
        do {
            _ = try await client.perform(StubTokenEndpoint.lookup())
            XCTFail("Expected throw")
        } catch MollieError.api(.serverError(503)) {
            // ok
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - Idempotency contract (Model B)

    //
    // GUARD TESTS — these pin the no-header / no-auto-retry contract for the
    // tokenise charging POST. `StubTokenEndpoint.lookup()` mirrors the real
    // `TokenizerEndpoint.tokenize` shape (POST v1/card-tokens, no auth), so the
    // client's POST retry behaviour these assert is exactly what governs
    // `tokenize`. They pass against current behaviour by design: POST is
    // excluded from `isIdempotent` (TokenizerClient.swift) and the SDK emits no
    // idempotency header — the PCI Tokeniser honours none. The point is
    // regression protection: auto-retrying a tokenise charge or adding an
    // idempotency header turns these red.

    func test_tokenize_urlError_doesNotRetry_chargingPostNotIdempotent() async {
        // A transient retryable URLError on the tokenise POST must result in
        // EXACTLY ONE attempt — never an auto-retry.
        var callCount = 0
        MockURLProtocol.handler = { _ in
            callCount += 1
            throw URLError(.timedOut)
        }
        let policy = RetryPolicy(maxAttempts: 3, baseDelay: 0)
        let client = makeClient(retryPolicy: policy)

        do {
            _ = try await client.perform(StubTokenEndpoint.lookup())
            XCTFail("Expected to throw")
        } catch MollieError.network {
            XCTAssertEqual(callCount, 1) // POST charge is never auto-retried
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func test_tokenize_serverError503_doesNotRetry_chargingPostNotIdempotent() async {
        // GUARD: a 5xx on the tokenise POST must be single-attempt. The new 5xx
        // retry path must stay gated on isIdempotent — POST is excluded — so a
        // server error never triggers an auto-retry of a charge.
        var callCount = 0
        MockURLProtocol.handler = { _ in
            callCount += 1
            return (.make(statusCode: 503), Data())
        }
        let policy = RetryPolicy(maxAttempts: 3, baseDelay: 0)
        let client = makeClient(retryPolicy: policy)

        do {
            _ = try await client.perform(StubTokenEndpoint.lookup())
            XCTFail("Expected to throw")
        } catch MollieError.api(.serverError(503)) {
            XCTAssertEqual(callCount, 1) // POST charge never auto-retried on 5xx
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func test_tokenize_offline_doesNotRetry_mapsToNetwork() async {
        // Offline is a *different* retryable URLError code than .timedOut
        // (already covered above): .notConnectedToInternet is in RetryPolicy's
        // retryableCodes set, so this proves the POST-not-retried gate holds
        // across every retryable URLError — not just timeout — and the error
        // surfaces as MollieError.network, distinct from the .timedOut guard covered above.
        var callCount = 0
        MockURLProtocol.handler = { _ in
            callCount += 1
            throw URLError(.notConnectedToInternet)
        }
        let policy = RetryPolicy(maxAttempts: 3, baseDelay: 0)
        let client = makeClient(retryPolicy: policy)

        do {
            _ = try await client.perform(StubTokenEndpoint.lookup())
            XCTFail("Expected to throw")
        } catch let MollieError.network(urlError) {
            XCTAssertEqual(callCount, 1) // POST charge never auto-retried, even offline
            XCTAssertEqual(urlError.code, .notConnectedToInternet)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func test_tokenize_emitsNoIdempotencyHeader() async throws {
        // Assert the deliberate absence of any idempotency header — the PCI
        // tokeniser honours none, so emitting one would be false protection.
        MockURLProtocol.handler = { request in
            self.capturedRequest = request
            return (.make(statusCode: 200), Data(#"{"value":"tok","last4":"4242"}"#.utf8))
        }
        let client = makeClient()
        _ = try await client.perform(StubTokenEndpoint.lookup())
        XCTAssertNil(capturedRequest?.value(forHTTPHeaderField: "Idempotency-Key"))
        XCTAssertNil(capturedRequest?.value(forHTTPHeaderField: "Idempotency-Token"))
        XCTAssertNil(capturedRequest?.value(forHTTPHeaderField: "X-Idempotency-Key"))
    }
}

private struct StubTokenResponse: Decodable {
    let value: String
    let last4: String
}

private enum StubTokenEndpoint {
    static func lookup(headers: [String: String] = [:]) -> Endpoint<StubTokenResponse> {
        Endpoint(path: "v1/card-tokens", method: .post, body: nil, requiresAuth: false, headers: headers)
    }
}
