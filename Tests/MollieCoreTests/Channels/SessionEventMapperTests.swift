import XCTest
@testable import MollieCore

/// Verifies the shared wire→event mapper that backs BOTH the Pusher-sourced
/// re-fetch and the HTTP-poll fallback. The two paths MUST map identical
/// `SessionResponse`s to identical `ChannelEvent`s — this suite locks the
/// invariants the SDK relies on:
///   - only `status == .completed` is terminal success (a `redirect`
///     actionType is NOT terminal),
///   - the challenge URL is read from `params["challenge_url"]` (snake_case
///     raw key, not converted by keyDecodingStrategy),
///   - every surfaced URL passes the `isUnsafeNavigation` gate.
final class SessionEventMapperTests: XCTestCase {
    private func decodeSession(_ json: String) throws -> SessionResponse {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(SessionResponse.self, from: Data(json.utf8))
    }

    // MARK: - completed (terminal success)

    func test_map_completedStatus_isSessionCompleted() throws {
        let json = """
        {
            "session_token": "sess_abc123",
            "status": "completed",
            "next_action": { "action_type": "none" },
            "payment_amount": { "amount": "10.00", "currency": "EUR" }
        }
        """
        let response = try decodeSession(json)
        guard case let .sessionCompleted(mapped) = SessionEventMapper.map(response: response) else {
            return XCTFail("Expected .sessionCompleted")
        }
        XCTAssertEqual(mapped.sessionToken, "sess_abc123")
    }

    // MARK: - expired (terminal failure)

    func test_map_expiredStatus_isSessionFailed_terminal() throws {
        // Regression guard: the legacy SessionPoller.poll() treated
        // `status == .expired` as terminal (alongside `.completed`). When the
        // mapping was consolidated into SessionEventMapper, expired fell through
        // to the non-terminal `.sessionUpdated`, so observeAttempt/pollAttempt
        // kept polling a dead session until the budget raised
        // MollieError.timeout — the merchant saw a timeout instead of a clean
        // expiry. Expired must map to a TERMINAL `.sessionFailed` carrying an
        // expiry-specific ProblemDetails.
        let json = """
        {
            "session_token": "sess_abc123",
            "status": "expired",
            "next_action": { "action_type": "none" },
            "payment_amount": { "amount": "10.00", "currency": "EUR" }
        }
        """
        let response = try decodeSession(json)
        let event = SessionEventMapper.map(response: response)
        guard case let .sessionFailed(details) = event else {
            return XCTFail("Expected .sessionFailed for expired status, got \(event)")
        }
        XCTAssertEqual(details?.title, "session_expired")
        XCTAssertTrue(SessionEventMapper.isTerminal(event), "expired must be terminal")
    }

    // MARK: - threeDsChallenge (challengeUrl / acsURL / challenge_url)

    func test_map_threeDSChallenge_snakeCaseChallengeURL_isChallengeReady() throws {
        let json = """
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
        let response = try decodeSession(json)
        guard case let .threeDSChallengeReady(url) = SessionEventMapper.map(response: response) else {
            return XCTFail("Expected .threeDSChallengeReady")
        }
        XCTAssertEqual(url.absoluteString, "https://3ds.example.com/challenge")
    }

    func test_map_threeDSChallenge_camelCaseChallengeURL_isChallengeReady() throws {
        // Production (PayProc path) emits `challengeUrl` (camelCase),
        // NOT `challenge_url`. A prior version read only `challenge_url`, so the
        // real production challenge was silently dropped → the WebView never
        // presented and polling timed out. The mapper must match this key.
        let json = """
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
        let response = try decodeSession(json)
        guard case let .threeDSChallengeReady(url) = SessionEventMapper.map(response: response) else {
            return XCTFail("Expected .threeDSChallengeReady for camelCase `challengeUrl`")
        }
        XCTAssertEqual(url.absoluteString, "https://3ds.example.com/challenge")
    }

    func test_map_threeDSChallenge_acsURLKey_isChallengeReady() throws {
        // The 3DS-v2 event path emits the ACS URL under `acsURL`.
        let json = """
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
        let response = try decodeSession(json)
        guard case let .threeDSChallengeReady(url) = SessionEventMapper.map(response: response) else {
            return XCTFail("Expected .threeDSChallengeReady for `acsURL`")
        }
        XCTAssertEqual(url.absoluteString, "https://3ds.example.com/challenge")
    }

    func test_map_threeDSChallenge_unsafeURL_isSessionFailed() throws {
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
        let response = try decodeSession(json)
        guard case let .sessionFailed(details) = SessionEventMapper.map(response: response) else {
            return XCTFail("Expected .sessionFailed for unsafe challenge URL")
        }
        XCTAssertEqual(details?.title, "invalid_configuration")
    }

    // MARK: - threeDsChallenge with a HOSTED pay URL → redirect path

    func test_map_threeDSChallenge_hostedPayURL_isRedirectRequired_noRedirectStripped() throws {
        // Regression guard for the production white-page bug. The server sends
        // actionType=threeDsChallenge with a HOSTED pay URL
        // (`pay.mollie.nl/payment/prepare-authentication/…?no_redirect=true`)
        // that emits NO `mollie-interceptor` postMessage. Routing it to
        // `.threeDSChallengeReady` drives the interceptor presenter, which
        // hangs on a blank page waiting for a postMessage that never comes
        // until the 15s watchdog fires. A hosted pay page must instead take the
        // eager hosted path via `.redirectRequired`. The `no_redirect=true`
        // query item must also be stripped — it suppresses the top-frame
        // redirect that advances the flow, stalling the hosted page on a blank
        // screen in the SDK's WKWebView (no interceptor JS to drive it).
        let json = """
        {
            "session_token": "sess_abc123",
            "status": "open",
            "next_action": {
                "action_type": "threeDsChallenge",
                "params": { "challengeUrl": "https://pay.mollie.nl/payment/prepare-authentication/abc?no_redirect=true" }
            },
            "payment_amount": { "amount": "10.00", "currency": "EUR" }
        }
        """
        let response = try decodeSession(json)
        let event = SessionEventMapper.map(response: response)
        guard case let .redirectRequired(url) = event else {
            return XCTFail("Expected .redirectRequired for hosted pay URL, got \(event)")
        }
        XCTAssertFalse(
            url.absoluteString.contains("no_redirect"),
            "no_redirect must be stripped so the hosted page can redirect normally"
        )
        if case .threeDSChallengeReady = event {
            XCTFail("A hosted pay URL must never surface .threeDSChallengeReady")
        }
    }

    func test_map_threeDSChallenge_hostedPayURL_stripsOnlyNoRedirect_keepsOtherParams() throws {
        // Stripping must be surgical: only `no_redirect` is removed; any other
        // query item the hosted URL carries (e.g. an id/token) is preserved so
        // the redirect target stays intact.
        let json = """
        {
            "session_token": "sess_abc123",
            "status": "open",
            "next_action": {
                "action_type": "threeDsChallenge",
                "params": { "challengeUrl": "https://pay.mollie.nl/payment/prepare-authentication/abc?foo=bar&no_redirect=true" }
            },
            "payment_amount": { "amount": "10.00", "currency": "EUR" }
        }
        """
        let response = try decodeSession(json)
        let event = SessionEventMapper.map(response: response)
        guard case let .redirectRequired(url) = event else {
            return XCTFail("Expected .redirectRequired for hosted pay URL, got \(event)")
        }
        XCTAssertFalse(url.absoluteString.contains("no_redirect"), "no_redirect must be dropped")
        XCTAssertTrue(url.absoluteString.contains("foo=bar"), "unrelated query items must be preserved")
    }

    func test_map_threeDSChallenge_interceptorHost_stillChallengeReady() throws {
        // Real interceptor challenge URLs use a non-hosted host (e.g.
        // `secure-3ds.mollie.com`) and DO emit `mollie-interceptor`
        // postMessages, so they must still map to `.threeDSChallengeReady` and
        // drive the interceptor presenter — the host-based routing must NOT
        // divert them to the redirect path.
        let json = """
        {
            "session_token": "sess_abc123",
            "status": "open",
            "next_action": {
                "action_type": "threeDsChallenge",
                "params": { "challengeUrl": "https://secure-3ds.mollie.com/challenge/abc" }
            },
            "payment_amount": { "amount": "10.00", "currency": "EUR" }
        }
        """
        let response = try decodeSession(json)
        let event = SessionEventMapper.map(response: response)
        guard case let .threeDSChallengeReady(url) = event else {
            return XCTFail("Expected .threeDSChallengeReady for interceptor host, got \(event)")
        }
        XCTAssertEqual(url.absoluteString, "https://secure-3ds.mollie.com/challenge/abc")
    }

    // MARK: - redirect (non-terminal)

    func test_map_redirectActionType_isRedirectRequired_notTerminal() throws {
        let json = """
        {
            "session_token": "sess_abc123",
            "status": "open",
            "next_action": {
                "action_type": "redirect",
                "params": { "url": "https://merchant.example.com/return?id=abc" }
            },
            "payment_amount": { "amount": "10.00", "currency": "EUR" }
        }
        """
        let response = try decodeSession(json)
        guard case let .redirectRequired(url) = SessionEventMapper.map(response: response) else {
            return XCTFail("Expected .redirectRequired (non-terminal)")
        }
        XCTAssertEqual(url.absoluteString, "https://merchant.example.com/return?id=abc")
    }

    func test_map_redirectActionType_unsafeURL_isSessionFailed() throws {
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
        let response = try decodeSession(json)
        guard case let .sessionFailed(details) = SessionEventMapper.map(response: response) else {
            return XCTFail("Expected .sessionFailed for loopback redirect URL")
        }
        XCTAssertEqual(details?.title, "invalid_configuration")
    }

    // MARK: - error

    func test_map_errorActionType_synthesizesProblemDetailsFromParams() throws {
        let json = """
        {
            "session_token": "sess_abc123",
            "status": "open",
            "next_action": {
                "action_type": "error",
                "params": {
                    "title": "Payment declined",
                    "detail": "Insufficient funds"
                }
            },
            "payment_amount": { "amount": "10.00", "currency": "EUR" }
        }
        """
        let response = try decodeSession(json)
        guard case let .sessionFailed(details) = SessionEventMapper.map(response: response) else {
            return XCTFail("Expected .sessionFailed for error actionType")
        }
        XCTAssertEqual(details?.title, "Payment declined")
        XCTAssertEqual(details?.detail, "Insufficient funds")
    }

    func test_map_errorActionType_emptyParams_detailFallsBackToUnknown() throws {
        let json = """
        {
            "session_token": "sess_abc123",
            "status": "open",
            "next_action": { "action_type": "error" },
            "payment_amount": { "amount": "10.00", "currency": "EUR" }
        }
        """
        let response = try decodeSession(json)
        guard case let .sessionFailed(details) = SessionEventMapper.map(response: response) else {
            return XCTFail("Expected .sessionFailed")
        }
        XCTAssertEqual(details?.detail, "unknown")
    }

    // MARK: - reset / soft-decline (retryable, non-terminal)

    //
    // Decision rule: retryable soft-decline ⇔
    // `actionType == "error"` AND `params.reset == true` (authentication/
    // authorization declined), OR bare `actionType == "reset"` (shopper
    // cancelled 3DS). Everything else (`error` without `reset`, e.g.
    // INTERNAL_PAYMENT_API_ERROR) stays terminal.

    func test_map_bareResetActionType_isAttemptFailed_notTerminal() throws {
        // The server sends actionType=reset with NO
        // params (PHP empty-array `[]`, decoded as `params == nil`). Before
        // this branch existed, `reset` fell through unmatched to the
        // catch-all `.sessionUpdated`, silently hanging the SDK's polling
        // until its own timeout budget fired instead of surfacing the
        // cancelled attempt.
        let json = """
        {
            "session_token": "sess_abc123",
            "status": "open",
            "next_action": { "action_type": "reset" },
            "payment_amount": { "amount": "10.00", "currency": "EUR" }
        }
        """
        let response = try decodeSession(json)
        let event = SessionEventMapper.map(response: response)
        guard case .attemptFailed = event else {
            return XCTFail("Expected .attemptFailed for bare reset actionType, got \(event)")
        }
        XCTAssertFalse(SessionEventMapper.isTerminal(event), "bare reset must be NON-terminal (retryable)")
    }

    func test_map_errorActionType_withResetTrue_isAttemptFailed_notTerminal() throws {
        // This wire shape: actionType=error,
        // params = { error: { type, detail }, reset: true }. `reset` is a
        // literal top-level key in `params` — NOT nested under `error` — and
        // is a raw JSON boolean, not a snake_case-converted field.
        let json = """
        {
            "session_token": "sess_abc123",
            "status": "open",
            "next_action": {
                "action_type": "error",
                "params": {
                    "error": {
                        "type": "authentication:default:error",
                        "detail": "Unexpected error occurred. Please try again later."
                    },
                    "reset": true
                }
            },
            "payment_amount": { "amount": "10.00", "currency": "EUR" }
        }
        """
        let response = try decodeSession(json)
        let event = SessionEventMapper.map(response: response)
        guard case let .attemptFailed(details) = event else {
            return XCTFail("Expected .attemptFailed for error actionType with params.reset == true, got \(event)")
        }
        XCTAssertFalse(SessionEventMapper.isTerminal(event), "error+reset=true must be NON-terminal (retryable)")
        XCTAssertEqual(details?.title, "authentication:default:error")
        XCTAssertEqual(details?.detail, "Unexpected error occurred. Please try again later.")
    }

    func test_map_errorActionType_withoutReset_staysSessionFailed_terminal() throws {
        // This wire shape (INTERNAL_PAYMENT_API_ERROR): actionType
        // =error, params carries NO `reset` key at all. The server allows a
        // retry but omits the marker the client relies on — this must stay
        // mapped to the terminal `.sessionFailed`, unchanged from before this
        // task's reset/error+reset branches were added.
        let json = """
        {
            "session_token": "sess_abc123",
            "status": "open",
            "next_action": {
                "action_type": "error",
                "params": {
                    "error": { "type": "general", "detail": "Unexpected error occurred. Please try again later." }
                }
            },
            "payment_amount": { "amount": "10.00", "currency": "EUR" }
        }
        """
        let response = try decodeSession(json)
        let event = SessionEventMapper.map(response: response)
        guard case let .sessionFailed(details) = event else {
            return XCTFail("Expected .sessionFailed for error actionType without reset, got \(event)")
        }
        XCTAssertTrue(SessionEventMapper.isTerminal(event), "error without reset must remain terminal")
        XCTAssertEqual(details?.title, "general")
    }

    func test_map_errorActionType_resetFalse_staysSessionFailed_terminal() throws {
        // Defensive: an explicit `reset: false` (never actually sent
        // server-side today, but a plausible future wire value) must not be
        // treated as truthy by the literal-key lookup.
        let json = """
        {
            "session_token": "sess_abc123",
            "status": "open",
            "next_action": {
                "action_type": "error",
                "params": { "reset": false }
            },
            "payment_amount": { "amount": "10.00", "currency": "EUR" }
        }
        """
        let response = try decodeSession(json)
        let event = SessionEventMapper.map(response: response)
        guard case .sessionFailed = event else {
            return XCTFail("Expected .sessionFailed for reset=false, got \(event)")
        }
        XCTAssertTrue(SessionEventMapper.isTerminal(event))
    }

    // MARK: - intermediate (readyToProcess / await → keep polling)

    func test_map_readyToProcess_isSessionUpdated_notTerminal() throws {
        let json = """
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
        let response = try decodeSession(json)
        guard case .sessionUpdated = SessionEventMapper.map(response: response) else {
            return XCTFail("Expected .sessionUpdated for readyToProcess")
        }
    }

    // MARK: - server-sourced URLs are https-only

    /// `isSafeRemoteURL` must be STRICTER than `isUnsafeNavigation`: the latter
    /// deliberately allows `data:` / `blob:` / `about:` for in-frame ACS content
    /// the 3DS WebView navigates to, but those are NOT legitimate for a
    /// top-level URL the server hands us. A `data:text/html,<script>…</script>`
    /// challenge would otherwise load and execute in the WebView. The mapper
    /// runs BEFORE the WebView's own gate, so it must reject non-https here.
    func test_map_threeDSChallenge_dataURL_yieldsSessionFailed() throws {
        let json = """
        {
            "session_token": "sess_abc123",
            "status": "open",
            "next_action": {
                "action_type": "threeDsChallenge",
                "params": { "challenge_url": "data:text/html,<script>alert(1)</script>" }
            },
            "payment_amount": { "amount": "10.00", "currency": "EUR" }
        }
        """
        let response = try decodeSession(json)
        let event = SessionEventMapper.map(response: response)
        guard case let .sessionFailed(details) = event else {
            return XCTFail("Expected .sessionFailed for data: challenge URL, got \(event)")
        }
        XCTAssertEqual(details?.title, "invalid_configuration")
        if case .threeDSChallengeReady = event {
            XCTFail("A data: challenge URL must never surface .threeDSChallengeReady")
        }
    }

    func test_map_redirect_blobURL_yieldsSessionFailed() throws {
        let json = """
        {
            "session_token": "sess_abc123",
            "status": "open",
            "next_action": {
                "action_type": "redirect",
                "params": { "url": "blob:https://evil.example.com/abc" }
            },
            "payment_amount": { "amount": "10.00", "currency": "EUR" }
        }
        """
        let response = try decodeSession(json)
        let event = SessionEventMapper.map(response: response)
        guard case let .sessionFailed(details) = event else {
            return XCTFail("Expected .sessionFailed for blob: redirect URL, got \(event)")
        }
        XCTAssertEqual(details?.title, "invalid_configuration")
    }

    /// https URLs still pass the stricter gate (the happy path is unchanged).
    func test_map_threeDSChallenge_httpsURL_stillReady() throws {
        let json = """
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
        let response = try decodeSession(json)
        guard case let .threeDSChallengeReady(url) = SessionEventMapper.map(response: response) else {
            return XCTFail("Expected .threeDSChallengeReady for https challenge URL")
        }
        XCTAssertEqual(url.absoluteString, "https://3ds.example.com/challenge")
    }
}
