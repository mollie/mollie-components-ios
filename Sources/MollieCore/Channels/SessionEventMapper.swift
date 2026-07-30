import Foundation

/// Shared wire→event mapper for a single `SessionResponse`. Both the
/// Pusher-sourced re-fetch and the HTTP-poll fallback funnel their decoded
/// responses through `map(response:)` so the two paths emit byte-identical
/// `ChannelEvent`s — there is exactly one place that decides what a session
/// state means.
///
/// Note on V2 contract: the 3DS ACS URL arrives under `challengeUrl` (camelCase,
/// PayProc path) or `acsURL` (3DS-v2 path); the dev-harness/mock uses
/// `challenge_url` (snake_case). Dictionary keys are NOT subject to
/// keyDecodingStrategy conversion, so `threeDSChallengeURL(from:)` matches all
/// literal wire forms (reading only `challenge_url` dropped the
/// real production challenge and hung polling).
package enum SessionEventMapper {
    package static func map(response: SessionResponse) -> ChannelEvent {
        // Terminal: status flipped to completed (the canonical success signal).
        if case .known(.completed) = response.status {
            return .sessionCompleted(response)
        }
        // Terminal: status flipped to expired. The legacy SessionPoller.poll()
        // treated `status == .expired` as terminal alongside `.completed`;
        // mapping it to `.sessionFailed` preserves that end-to-end behavior so a
        // dead session resolves cleanly as `MollieError.sessionFailed` instead
        // of polling on until the budget raises `MollieError.timeout`. There is
        // no `ChannelEvent.sessionExpired` case, and `MollieError.sessionExpired`
        // is reserved/not-emitted — `.sessionFailed` with an expiry-specific
        // ProblemDetails is the faithful terminal mapping.
        if case .known(.expired) = response.status {
            return .sessionFailed(ProblemDetails(
                title: "session_expired",
                detail: "The payment session has expired"
            ))
        }
        // 3DS challenge: intermediate. SDK must open the ACS URL, then the
        // server transitions back to readyToProcess once authentication resolves.
        // URL is validated at the mapper (scheme + lexical safety) — a hostile
        // server response with `javascript:` / `data:` / loopback / RFC1918 host
        // is rejected here, before the WebView is even constructed.
        if let url = threeDSChallengeURL(from: response) {
            if isSafeRemoteURL(url) {
                // Route by host, not just actionType. In production the server
                // sends `threeDsChallenge` with a HOSTED pay URL
                // (`pay.mollie.nl/payment/prepare-authentication/…?no_redirect=true`)
                // that renders a normal hosted page and emits NO
                // `mollie-interceptor` postMessage. The interceptor presenter
                // driven by `.threeDSChallengeReady` waits for that postMessage
                // to reveal, so a hosted URL there hangs on a blank page until
                // the watchdog fires (production white-page bug). Hosted pay
                // pages must take the eager hosted path via `.redirectRequired`
                // instead. Real interceptor challenges use a different host
                // (e.g. `secure-3ds.mollie.com`) and still map to
                // `.threeDSChallengeReady`.
                if isHostedMolliePayURL(url) {
                    return .redirectRequired(strippingNoRedirect(url))
                }
                return .threeDSChallengeReady(url)
            }
            return .sessionFailed(ProblemDetails(
                title: "invalid_configuration",
                detail: "Unsafe 3DS challenge URL"
            ))
        }
        // Non-terminal: server emitted `redirect` — the host must navigate the
        // user to the supplied URL (Mollie's hosted prepare-authentication /
        // final-screen page) and let the session continue. The URL covers
        // BOTH the mid-flow 3DS handoff (`pay.mollie.nl/payment/prepare-
        // authentication/…`) AND the post-payment merchant return; only the
        // subsequent `status=completed` poll signals real success.
        //
        // History: previously this branch mapped to `.sessionCompleted`,
        // which caused the SDK to claim success on every redirect event —
        // including mid-flow 3DS handoffs where the payment was still open.
        // swiftlint:disable opening_brace
        if case .known(.redirect) = response.nextAction.actionType,
           let raw = response.nextAction.params?["url"]?.value as? String,
           let url = URL(string: raw)
        {
            // Same gate as the 3DS branch: validate scheme + host BEFORE
            // surfacing the URL to the coordinator / WebView. Prevents a
            // compromised or misbehaving session response from steering the
            // user to `javascript:alert(…)` or a loopback exfil endpoint.
            if isSafeRemoteURL(url) {
                return .redirectRequired(url)
            }
            return .sessionFailed(ProblemDetails(
                title: "invalid_configuration",
                detail: "Unsafe redirect URL"
            ))
        }
        // swiftlint:enable opening_brace
        // Non-terminal: bare `reset` — the shopper cancelled 3-D Secure
        // authentication. The Sessions Service resets the session and
        // accepts a fresh attempt. Before this branch existed, `reset`
        // fell through unmatched to the catch-all `.sessionUpdated`, which
        // gives the caller no signal that the attempt failed — the SDK
        // just silently re-polled the same session until its own timeout
        // budget fired.
        if case .known(.reset) = response.nextAction.actionType {
            return .attemptFailed(makeProblemDetails(from: response.nextAction.params))
        }
        // Per-attempt error from the checkout-attempt path. Two sub-cases,
        // distinguished by the literal `reset` key in `params` — an ad-hoc
        // array key server-side, not a typed contract field:
        //   - `reset == true`: authorization declined / 3DS auth failed.
        //     Session resets to CREATED (non-final) — NON-terminal.
        //   - `reset` absent (e.g. INTERNAL_PAYMENT_API_ERROR): a genuine
        //     backend/API error the server does not mark retryable —
        //     terminal, unchanged from before this task.
        // Either way, synthesize a ProblemDetails from `nextAction.params` so
        // callers retain SOME context instead of dropping the payload
        // (previously `.sessionFailed(nil)`).
        if case .known(.error) = response.nextAction.actionType {
            let details = makeProblemDetails(from: response.nextAction.params)
            if isRetryableReset(response.nextAction.params) {
                return .attemptFailed(details)
            }
            return .sessionFailed(details)
        }
        // Intermediate (incl. readyToProcess): the server is auto-processing
        // the payment on its own. Client just keeps polling.
        return .sessionUpdated(response)
    }

    package static func isTerminal(_ event: ChannelEvent) -> Bool {
        switch event {
        case .sessionCompleted, .sessionFailed: true
        case .sessionUpdated, .threeDSChallengeReady, .redirectRequired, .attemptFailed: false
        }
    }

    /// Defense-in-depth filter for URLs surfaced from the server's
    /// `nextAction.params`. The 3DS WebView also runs its own navigation gate
    /// before loading, but stopping the URL here means a hostile `javascript:`
    /// / `data:` / `blob:` / loopback payload never reaches a presented sheet
    /// at all — it surfaces as `.sessionFailed(invalid_configuration)` instead.
    ///
    /// Server-sourced redirect / 3DS challenge URLs are https-only. Note this
    /// is STRICTER than `isUnsafeNavigation`, which deliberately allows
    /// `about:` / `data:` / `blob:` because those are legitimate for in-frame
    /// ACS content the WebView navigates to — but they are NOT legitimate for a
    /// top-level URL the server hands us. A `data:text/html,<script>…</script>`
    /// challenge/redirect would otherwise load and execute in the WebView, so
    /// we require https here and then apply the shared host checks (IP-literal
    /// / localhost / cloud-metadata rejection).
    static func isSafeRemoteURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https" else { return false }
        // `isUnsafeNavigation` adds lexical IP-literal / localhost / metadata
        // rejection on top of the https requirement. `false` means safe.
        return !isUnsafeNavigation(url: url)
    }

    /// Whether `url` is a Mollie HOSTED pay page (`pay.mollie.nl` /
    /// `pay.mollie.com`, case-insensitive). Such a page renders normally but
    /// emits NO `mollie-interceptor` postMessage, so a `threeDsChallenge`
    /// next-action carrying one must be driven by the eager hosted presenter
    /// (`.redirectRequired`) rather than the interceptor presenter
    /// (`.threeDSChallengeReady`), which would hang waiting for a postMessage
    /// that never arrives. Real interceptor challenge URLs use a different host
    /// (e.g. `secure-3ds.mollie.com`) and return `false` here.
    static func isHostedMolliePayURL(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return ["pay.mollie.nl", "pay.mollie.com"].contains(host)
    }

    /// Remove the `no_redirect` query item from a hosted pay URL. The server
    /// returns the hosted 3DS authentication URL with `no_redirect=true`, which
    /// suppresses the top-frame redirect that advances the flow — in the SDK's
    /// WKWebView (no interceptor JS to drive it) that leaves the page stalled on
    /// a blank screen. Stripping it lets the hosted page redirect normally to the
    /// challenge UI or the merchant return URL, both of which the WebView's
    /// navigation policy already handles.
    static func strippingNoRedirect(_ url: URL) -> URL {
        guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = comps.queryItems else { return url }
        let filtered = items.filter { $0.name.lowercased() != "no_redirect" }
        comps.queryItems = filtered.isEmpty ? nil : filtered
        return comps.url ?? url
    }

    static func threeDSChallengeURL(from response: SessionResponse) -> URL? {
        guard case .known(.threeDsChallenge) = response.nextAction.actionType else { return nil }
        // The 3DS challenge/ACS URL key varies by which backend path produced
        // the `threeDsChallenge` next-action:
        //   - PayProc path emits `challengeUrl` (camelCase)
        //   - the 3DS-v2 event path emits `acsURL`
        //   - the dev-harness/mock emits `challenge_url` (snake_case)
        // `params` is a raw [String: AnyCodable] dictionary, so its keys are NOT
        // run through `keyDecodingStrategy` — we must match the literal wire key.
        // Try the production keys first, then the mock/legacy fallbacks. Missing
        // the real key silently drops the challenge → the WebView never presents
        // and the poll times out.
        let params = response.nextAction.params
        let raw = (params?["challengeUrl"]?.value as? String)
            ?? (params?["acsURL"]?.value as? String)
            ?? (params?["challenge_url"]?.value as? String)
            ?? (params?["acs_url"]?.value as? String)
        guard let raw else { return nil }
        return URL(string: raw)
    }

    /// Synthesize a `ProblemDetails` from the per-attempt `nextAction.params`.
    /// Reads, in order of preference:
    ///   1. RFC7807-style top-level `title` / `detail`,
    ///   2. nested `error.{type,detail}` — the shape payment-processing
    ///      actually emits on terminal session failure,
    ///   3. top-level `error_code`,
    ///   4. literal "unknown" so callers always see a non-nil detail.
    static func makeProblemDetails(from params: [String: AnyCodable]?) -> ProblemDetails {
        let errorObject = params?["error"]?.value as? [String: Any]
        let title = (params?["title"]?.value as? String)
            ?? (errorObject?["type"] as? String)
        let detail = (params?["detail"]?.value as? String)
            ?? (errorObject?["detail"] as? String)
            ?? (params?["error_code"]?.value as? String)
            ?? "unknown"
        return ProblemDetails(title: title, detail: detail)
    }

    /// Whether `nextAction.params` carries the server's ad-hoc `reset: true`
    /// marker for a retryable soft decline, verified against the Sessions
    /// Service's actual behavior rather than a mock. `params` is a raw
    /// `[String: AnyCodable]` dictionary — NOT run through
    /// `keyDecodingStrategy` — so this matches the literal wire key the same
    /// way `threeDSChallengeURL(from:)` above matches literal `challengeUrl`/
    /// `acsURL` keys instead of relying on case conversion. The wire value is
    /// always a native JSON boolean; a non-boolean or missing key is treated
    /// as "not retryable" rather than throwing.
    static func isRetryableReset(_ params: [String: AnyCodable]?) -> Bool {
        (params?["reset"]?.value as? Bool) == true
    }
}
