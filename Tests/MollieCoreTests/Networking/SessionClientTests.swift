import XCTest
@testable import MollieCore

final class SessionClientTests: XCTestCase {
    private let baseURL = URL(string: "https://sessions.mollie.com") ?? URL(fileURLWithPath: "/")
    private let token = "eyJzZXNzaW9uVG9rZW4iOiJzZXNzX2FiYyJ9"

    private func makeClient(retryPolicy: RetryPolicy = RetryPolicy(maxAttempts: 1, baseDelay: 0)) -> SessionClient {
        SessionClient(
            baseURL: baseURL,
            clientAccessToken: token,
            retryPolicy: retryPolicy,
            session: .makeMockSession()
        )
    }

    private var capturedRequest: URLRequest?

    // MARK: - Headers

    func test_perform_injectsAuthorizationHeader() async throws {
        MockURLProtocol.handler = { request in
            self.capturedRequest = request
            let response = try self.makeSessionJSON()
            return (.make(statusCode: 200), response)
        }
        let client = makeClient()
        _ = try await client.perform(SessionEndpoint.get(sessionToken: "sess_abc"))
        XCTAssertEqual(capturedRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer \(token)")
    }

    func test_perform_withBody_injectsContentTypeHeader() async throws {
        MockURLProtocol.handler = { request in
            self.capturedRequest = request
            return try (.make(statusCode: 200), self.makeSessionJSON())
        }
        let client = makeClient()
        let body = UpdateDetailsRequest(
            paymentMethodDetails: PaymentMethodDetailsRequest(method: "creditcard", cardToken: "tok_abc"),
            fingerprint: DeviceFingerprint(
                language: "en-US", javascriptEnabled: false, screenWidth: "375",
                screenHeight: "812", timeZoneOffset: "0", javaEnabled: false, colorDepth: "24"
            )
        )
        _ = try await client.perform(SessionEndpoint.updateDetails(sessionToken: "sess_abc", body: body))
        XCTAssertEqual(capturedRequest?.value(forHTTPHeaderField: "Content-Type"), "application/json")
    }

    func test_perform_withoutBody_doesNotInjectContentTypeHeader() async throws {
        MockURLProtocol.handler = { request in
            self.capturedRequest = request
            return try (.make(statusCode: 200), self.makeSessionJSON())
        }
        let client = makeClient()
        _ = try await client.perform(SessionEndpoint.get(sessionToken: "sess_abc"))
        XCTAssertNil(capturedRequest?.value(forHTTPHeaderField: "Content-Type"))
    }

    // MARK: - Success

    func test_perform_200_decodesSessionResponse() async throws {
        MockURLProtocol.handler = { _ in try (.make(statusCode: 200), self.makeSessionJSON()) }
        let client = makeClient()
        let response = try await client.perform(SessionEndpoint.get(sessionToken: "sess_abc"))
        XCTAssertEqual(response.sessionToken, "sess_abc123")
        XCTAssertEqual(response.status, .known(.open))
    }

    // MARK: - HTTP errors

    func test_perform_401_throwsUnauthorized() async {
        MockURLProtocol.handler = { _ in (.make(statusCode: 401), Data()) }
        let client = makeClient()
        await assertThrowsAPIError(.unauthorized) {
            _ = try await client.perform(SessionEndpoint.get(sessionToken: "sess_abc"))
        }
    }

    func test_perform_403_throwsForbidden() async {
        MockURLProtocol.handler = { _ in (.make(statusCode: 403), Data()) }
        let client = makeClient()
        await assertThrowsAPIError(.forbidden) {
            _ = try await client.perform(SessionEndpoint.get(sessionToken: "sess_abc"))
        }
    }

    func test_perform_404_throwsNotFound() async {
        MockURLProtocol.handler = { _ in (.make(statusCode: 404), Data()) }
        let client = makeClient()
        await assertThrowsAPIError(.notFound) {
            _ = try await client.perform(SessionEndpoint.get(sessionToken: "sess_abc"))
        }
    }

    func test_perform_422_withViolations_throwsValidationFailed() async {
        let jsonString = """
        {"violations": [{"name": "amount", "reason": "must be positive"}]}
        """
        let body = Data(jsonString.utf8)
        MockURLProtocol.handler = { _ in (.make(statusCode: 422), body) }
        let client = makeClient()
        await assertThrowsAPIError(.validationFailed([Violation(name: "amount", reason: "must be positive")])) {
            _ = try await client.perform(SessionEndpoint.get(sessionToken: "sess_abc"))
        }
    }

    func test_perform_422_withoutViolations_throwsValidationFailedWithEmptyArray() async {
        MockURLProtocol.handler = { _ in (.make(statusCode: 422), Data()) }
        let client = makeClient()
        await assertThrowsAPIError(.validationFailed([])) {
            _ = try await client.perform(SessionEndpoint.get(sessionToken: "sess_abc"))
        }
    }

    func test_perform_409_throwsConflict() async {
        MockURLProtocol.handler = { _ in (.make(statusCode: 409), Data()) }
        let client = makeClient()
        await assertThrowsAPIError(.conflict(retryAfter: nil)) {
            _ = try await client.perform(SessionEndpoint.get(sessionToken: "sess_abc"))
        }
    }

    func test_perform_429_withRetryAfterHeader_throwsRateLimited() async {
        MockURLProtocol.handler = { _ in
            (.make(statusCode: 429, headers: ["Retry-After": "2"]), Data())
        }
        let client = makeClient()
        await assertThrowsAPIError(.rateLimited(retryAfter: 2)) {
            _ = try await client.perform(SessionEndpoint.get(sessionToken: "sess_abc"))
        }
    }

    func test_perform_500_throwsServerError() async {
        MockURLProtocol.handler = { _ in (.make(statusCode: 500), Data()) }
        let client = makeClient()
        await assertThrowsAPIError(.serverError(500)) {
            _ = try await client.perform(SessionEndpoint.get(sessionToken: "sess_abc"))
        }
    }

    // MARK: - Retry

    func test_urlError_onIdempotentRequest_retriesAndEventuallyThrowsNetwork() async {
        var callCount = 0
        MockURLProtocol.handler = { _ in
            callCount += 1
            throw URLError(.notConnectedToInternet)
        }
        let policy = RetryPolicy(maxAttempts: 2, baseDelay: 0)
        let client = makeClient(retryPolicy: policy)

        do {
            _ = try await client.perform(SessionEndpoint.get(sessionToken: "sess_abc"))
            XCTFail("Expected to throw")
        } catch MollieError.network {
            XCTAssertEqual(callCount, 3) // original + 2 retries (maxAttempts: 2)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func test_urlError_onNonIdempotentRequest_doesNotRetry() async {
        var callCount = 0
        MockURLProtocol.handler = { _ in
            callCount += 1
            throw URLError(.notConnectedToInternet)
        }
        let policy = RetryPolicy(maxAttempts: 3, baseDelay: 0)
        let client = makeClient(retryPolicy: policy)
        let body = UpdateDetailsRequest(
            paymentMethodDetails: PaymentMethodDetailsRequest(method: "creditcard", cardToken: "tok_abc"),
            fingerprint: DeviceFingerprint(
                language: "en-US", javascriptEnabled: false, screenWidth: "375",
                screenHeight: "812", timeZoneOffset: "0", javaEnabled: false, colorDepth: "24"
            )
        )

        do {
            _ = try await client.perform(SessionEndpoint.updateDetails(sessionToken: "sess_abc", body: body))
            XCTFail("Expected to throw")
        } catch MollieError.network {
            XCTAssertEqual(callCount, 1) // no retry on PATCH (non-idempotent)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func test_serverError503_onIdempotentRequest_retriesThenThrows() async {
        // 5xx on an idempotent GET is transient → retry up to maxAttempts.
        // Catches the bug where the retry catch handled only URLError and let a
        // retryable .serverError fall straight through unretried.
        var callCount = 0
        MockURLProtocol.handler = { _ in
            callCount += 1
            return (.make(statusCode: 503), Data())
        }
        let policy = RetryPolicy(maxAttempts: 2, baseDelay: 0)
        let client = makeClient(retryPolicy: policy)

        await assertThrowsAPIError(.serverError(503)) {
            _ = try await client.perform(SessionEndpoint.get(sessionToken: "sess_abc"))
        }
        XCTAssertEqual(callCount, 3) // original + 2 retries
    }

    func test_serverError503_onNonIdempotentPost_doesNotRetry() async {
        // GUARD: a 5xx on the charging POST must be single-attempt — no
        // server-honoured dedup exists (spike #316, Model B), so an auto-retry
        // risks a duplicate authorization.
        var callCount = 0
        MockURLProtocol.handler = { _ in
            callCount += 1
            return (.make(statusCode: 503), Data())
        }
        let policy = RetryPolicy(maxAttempts: 3, baseDelay: 0)
        let client = makeClient(retryPolicy: policy)
        let fingerprint = DeviceFingerprint(
            language: "en-US", javascriptEnabled: false, screenWidth: "375",
            screenHeight: "812", timeZoneOffset: "0", javaEnabled: false, colorDepth: "24"
        )
        let body = CreateCheckoutAttemptRequest(
            paymentMethod: "creditcard", checkoutMethod: "card",
            fingerprint: fingerprint, pspToken: "tok_abc", wallet: nil, walletToken: nil
        )

        await assertThrowsAPIError(.serverError(503)) {
            _ = try await client.perform(
                SessionEndpoint.createCheckoutAttempt(sessionToken: "sess_abc", body: body)
            )
        }
        XCTAssertEqual(callCount, 1) // POST charge never auto-retried, even on 5xx
    }

    func test_rateLimited429_onIdempotentRequest_honoursRetryAfter() async {
        // Idempotent GET hitting 429 retries, and the wait is driven by the
        // Retry-After header (not the jittered exponential). We assert the
        // retry happens; timing is verified deterministically in RetryPolicyTests.
        var callCount = 0
        MockURLProtocol.handler = { _ in
            callCount += 1
            return (.make(statusCode: 429, headers: ["Retry-After": "0"]), Data())
        }
        let policy = RetryPolicy(maxAttempts: 2, baseDelay: 0)
        let client = makeClient(retryPolicy: policy)

        await assertThrowsAPIError(.rateLimited(retryAfter: 0)) {
            _ = try await client.perform(SessionEndpoint.get(sessionToken: "sess_abc"))
        }
        XCTAssertEqual(callCount, 3) // original + 2 retries on 429
    }

    // MARK: - Idempotency contract (epic 315 / spike #316, Model B)

    //
    // GUARD TESTS — these pin the no-header / no-auto-retry contract for the
    // charging POST. They pass against current behaviour by design: POST is
    // excluded from `isIdempotent` (SessionClient.swift) and the SDK emits no
    // idempotency header. The point is regression protection — a future change
    // that auto-retries createCheckoutAttempt or adds an idempotency header
    // (which neither the Sessions Service nor the PCI tokeniser honours, per
    // spike #316) turns these red. See decisions-log "2026-06-23 — Network
    // idempotency model decided (spike #316 resolved)".

    func test_createCheckoutAttempt_urlError_doesNotRetry_chargingPostNotIdempotent() async {
        // A transient retryable URLError on the charging POST must result in
        // EXACTLY ONE attempt — never an auto-retry. Auto-retrying a charge
        // with no server-honoured dedup risks a duplicate authorization.
        var callCount = 0
        MockURLProtocol.handler = { _ in
            callCount += 1
            throw URLError(.timedOut)
        }
        let policy = RetryPolicy(maxAttempts: 3, baseDelay: 0)
        let client = makeClient(retryPolicy: policy)
        let fingerprint = DeviceFingerprint(
            language: "en-US", javascriptEnabled: false, screenWidth: "375",
            screenHeight: "812", timeZoneOffset: "0", javaEnabled: false, colorDepth: "24"
        )
        let body = CreateCheckoutAttemptRequest(
            paymentMethod: "creditcard", checkoutMethod: "card",
            fingerprint: fingerprint, pspToken: "tok_abc", wallet: nil, walletToken: nil
        )

        do {
            _ = try await client.perform(
                SessionEndpoint.createCheckoutAttempt(sessionToken: "sess_abc", body: body)
            )
            XCTFail("Expected to throw")
        } catch MollieError.network {
            XCTAssertEqual(callCount, 1) // POST charge is never auto-retried
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func test_createCheckoutAttempt_emitsNoIdempotencyHeader() async throws {
        // Neither the Sessions Service nor the tokeniser honours an inbound
        // idempotency key (spike #316). Assert the deliberate ABSENCE so a
        // future well-meaning addition — which would give false duplicate-
        // charge protection — is caught here.
        MockURLProtocol.handler = { request in
            self.capturedRequest = request
            let json = #"{"checkout_attempt_token": "cat_abc123"}"#
            return (.make(statusCode: 201), Data(json.utf8))
        }
        let client = makeClient()
        let fingerprint = DeviceFingerprint(
            language: "en-US", javascriptEnabled: false, screenWidth: "375",
            screenHeight: "812", timeZoneOffset: "0", javaEnabled: false, colorDepth: "24"
        )
        let body = CreateCheckoutAttemptRequest(
            paymentMethod: "creditcard", checkoutMethod: "card",
            fingerprint: fingerprint, pspToken: "tok_abc", wallet: nil, walletToken: nil
        )
        _ = try await client.perform(
            SessionEndpoint.createCheckoutAttempt(sessionToken: "sess_abc", body: body)
        )
        XCTAssertNil(capturedRequest?.value(forHTTPHeaderField: "Idempotency-Key"))
        XCTAssertNil(capturedRequest?.value(forHTTPHeaderField: "Idempotency-Token"))
        XCTAssertNil(capturedRequest?.value(forHTTPHeaderField: "X-Idempotency-Key"))
    }

    // MARK: - Checkout attempts

    func test_createCheckoutAttempt_201_decodesToken() async throws {
        let json = #"{"checkout_attempt_token": "cat_abc123"}"#
        MockURLProtocol.handler = { _ in (.make(statusCode: 201), Data(json.utf8)) }
        let client = makeClient()
        let fingerprint = DeviceFingerprint(
            language: "en-US", javascriptEnabled: false, screenWidth: "375",
            screenHeight: "812", timeZoneOffset: "0", javaEnabled: false, colorDepth: "24"
        )
        let body = CreateCheckoutAttemptRequest(
            paymentMethod: "creditcard", checkoutMethod: "card",
            fingerprint: fingerprint, pspToken: "tok_abc", wallet: nil, walletToken: nil
        )
        let response = try await client.perform(
            SessionEndpoint.createCheckoutAttempt(sessionToken: "sess_abc", body: body)
        )
        XCTAssertEqual(response.checkoutAttemptToken, "cat_abc123")
    }

    func test_createCheckoutAttempt_sendsPost() async throws {
        MockURLProtocol.handler = { request in
            self.capturedRequest = request
            let json = #"{"checkout_attempt_token": "cat_xyz"}"#
            return (.make(statusCode: 201), Data(json.utf8))
        }
        let client = makeClient()
        let fingerprint = DeviceFingerprint(
            language: "en-US", javascriptEnabled: false, screenWidth: "375",
            screenHeight: "812", timeZoneOffset: "0", javaEnabled: false, colorDepth: "24"
        )
        let body = CreateCheckoutAttemptRequest(
            paymentMethod: "creditcard", checkoutMethod: "card",
            fingerprint: fingerprint, pspToken: "tok_test", wallet: nil, walletToken: nil
        )
        _ = try await client.perform(
            SessionEndpoint.createCheckoutAttempt(sessionToken: "sess_abc", body: body)
        )
        XCTAssertEqual(capturedRequest?.httpMethod, "POST")
        XCTAssertEqual(capturedRequest?.value(forHTTPHeaderField: "Content-Type"), "application/json")
    }

    func test_createCheckoutAttemptRequest_encodesWebSDKContractFields() throws {
        // Verify CreateCheckoutAttemptRequest encodes the fields required by the web
        // SDK's checkout-attempt payload contract: paymentMethod="creditcard",
        // checkoutMethod="card", pspToken present, no extra keys.
        let fingerprint = DeviceFingerprint(
            language: "en-US", javascriptEnabled: false, screenWidth: "375",
            screenHeight: "812", timeZoneOffset: "0", javaEnabled: false, colorDepth: "24"
        )
        let request = CreateCheckoutAttemptRequest(
            paymentMethod: "creditcard", checkoutMethod: "card",
            fingerprint: fingerprint, pspToken: "tok_verify", wallet: nil, walletToken: nil
        )
        let data = try JSONEncoder().encode(request)
        let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(decoded?["paymentMethod"] as? String, "creditcard")
        XCTAssertEqual(decoded?["checkoutMethod"] as? String, "card")
        XCTAssertEqual(decoded?["pspToken"] as? String, "tok_verify")
        XCTAssertNotNil(decoded?["fingerprint"])
    }

    func test_getCheckoutAttempts_preservesTrailingSlashInRequestURL() async throws {
        // Regression: the backend routes on the literal `/checkout-attempts/`
        // path (trailing slash). URL normalization that strips it produces a
        // 404 in production — assert the request URL keeps the slash.
        MockURLProtocol.handler = { request in
            self.capturedRequest = request
            return (.make(statusCode: 200), Data(#"{}"#.utf8))
        }
        let client = makeClient()
        _ = try await client.perform(SessionEndpoint.getCheckoutAttempts(sessionToken: "sess_abc"))
        guard let url = capturedRequest?.url?.absoluteString else {
            XCTFail("captured request URL was nil")
            return
        }
        XCTAssertTrue(
            url.hasSuffix("/checkout-attempts/"),
            "Trailing slash on /checkout-attempts/ must be preserved (got \(url))"
        )
    }

    func test_getCheckoutAttempts_200_decodesStateMap() async throws {
        let sessionJSON = try makeSessionJSON()
        guard let sessionStr = String(bytes: sessionJSON, encoding: .utf8) else {
            XCTFail("Failed to decode session JSON as UTF-8")
            return
        }
        let json = #"{"cat_abc123": \#(sessionStr)}"#
        MockURLProtocol.handler = { _ in (.make(statusCode: 200), Data(json.utf8)) }
        let client = makeClient()
        let map = try await client.perform(
            SessionEndpoint.getCheckoutAttempts(sessionToken: "sess_abc")
        )
        XCTAssertNotNil(map["cat_abc123"])
        XCTAssertEqual(map["cat_abc123"]?.sessionToken, "sess_abc123")
    }

    func test_createCheckoutAttempt_409_throwsConflict() async {
        MockURLProtocol.handler = { _ in (.make(statusCode: 409), Data()) }
        let client = makeClient()
        let fingerprint = DeviceFingerprint(
            language: "en-US", javascriptEnabled: false, screenWidth: "375",
            screenHeight: "812", timeZoneOffset: "0", javaEnabled: false, colorDepth: "24"
        )
        let body = CreateCheckoutAttemptRequest(
            paymentMethod: "creditcard", checkoutMethod: "card",
            fingerprint: fingerprint, pspToken: nil, wallet: nil, walletToken: nil
        )
        await assertThrowsAPIError(.conflict(retryAfter: nil)) {
            _ = try await client.perform(
                SessionEndpoint.createCheckoutAttempt(sessionToken: "sess_abc", body: body)
            )
        }
    }

    func test_createCheckoutAttempt_422_throwsValidationFailed() async {
        let jsonString = """
        {"violations": [{"name": "pspToken", "reason": "required"}]}
        """
        MockURLProtocol.handler = { _ in (.make(statusCode: 422), Data(jsonString.utf8)) }
        let client = makeClient()
        let fingerprint = DeviceFingerprint(
            language: "en-US", javascriptEnabled: false, screenWidth: "375",
            screenHeight: "812", timeZoneOffset: "0", javaEnabled: false, colorDepth: "24"
        )
        let body = CreateCheckoutAttemptRequest(
            paymentMethod: "creditcard", checkoutMethod: "card",
            fingerprint: fingerprint, pspToken: nil, wallet: nil, walletToken: nil
        )
        await assertThrowsAPIError(.validationFailed([Violation(name: "pspToken", reason: "required")])) {
            _ = try await client.perform(
                SessionEndpoint.createCheckoutAttempt(sessionToken: "sess_abc", body: body)
            )
        }
    }

    // MARK: - Helpers

    private func makeSessionJSON() throws -> Data {
        let json = """
        {
            "session_token": "sess_abc123",
            "status": "open",
            "next_action": { "action_type": "await" },
            "payment_amount": { "amount": "10.00", "currency": "EUR" }
        }
        """
        return Data(json.utf8)
    }

    private func assertThrowsAPIError(
        _ expected: MollieError.APIError,
        block: () async throws -> Void,
        file: StaticString = #file,
        line: UInt = #line
    ) async {
        do {
            try await block()
            XCTFail("Expected MollieError.api(\(expected)) to be thrown", file: file, line: line)
        } catch let MollieError.api(actual) {
            XCTAssertEqual(actual, expected, file: file, line: line)
        } catch {
            XCTFail("Expected MollieError.api but got \(error)", file: file, line: line)
        }
    }
}
