import Foundation
import MollieCore

/// Merges Pusher channel events with session-polling fallback into a single ChannelEvent stream.
/// Phase 2 ships with a no-op channels client (Pusher integration deferred), so the consumer
/// falls back entirely to polling. The interface stays Pusher-shaped so a future swap to the
/// real PusherChannelsClient is configuration-only.
///
/// Two polling modes:
///  - Legacy (`observe(sessionToken:)`): polls `GET /sessions/{token}` via `SessionPoller.poll()`.
///  - Checkout-attempt (`observeAttempt()`): polls `GET /checkout-attempts/` via
///    `SessionPoller.pollAttempt()`. The `checkoutAttemptToken` is baked into the poller at
///    construction time; no second arg here so we cannot drift from the poller's view.
///
/// Note on V2 contract: the 3DS ACS URL arrives under `nextAction.params.challengeUrl` (camelCase,
/// PayProc path) or `params.acsURL` (3DS-v2 path); the dev-harness/mock uses `challenge_url`.
/// Dictionary keys are NOT subject to keyDecodingStrategy conversion, so `threeDSChallengeURL(from:)`
/// matches all literal forms (see PXP-5009 — reading only `challenge_url` dropped the real prod
/// challenge and hung polling).
package final class SessionEventConsumer: Sendable {
    private let channelsClient: any MollieChannelsClient
    private let sessionPoller: SessionPoller

    package init(channelsClient: any MollieChannelsClient, sessionPoller: SessionPoller) {
        self.channelsClient = channelsClient
        self.sessionPoller = sessionPoller
    }

    package func observe(sessionToken: String) -> AsyncThrowingStream<ChannelEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [channelsClient, sessionPoller] in
                // Drain the (no-op) channels stream first; immediately falls through.
                if let stream = try? await channelsClient.subscribe(to: sessionToken) {
                    for await event in stream {
                        continuation.yield(event)
                    }
                }
                // Now poll for session updates.
                do {
                    for try await response in sessionPoller.poll() {
                        Self.yieldEvents(for: response, into: continuation)
                        if Self.isTerminal(Self.map(response: response)) {
                            continuation.finish()
                            return
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    package func observeAttempt(sessionToken: String) -> AsyncThrowingStream<ChannelEvent, Error> {
        AsyncThrowingStream<ChannelEvent, Error> { continuation in
            let task = Task { [channelsClient, sessionPoller] in
                // Drain the (no-op) channels stream first; immediately falls through.
                if let stream = try? await channelsClient.subscribe(to: sessionToken) {
                    for await event in stream {
                        continuation.yield(event)
                    }
                }
                // Poll per-attempt state; checkoutAttemptToken is baked into the poller.
                do {
                    for try await response in sessionPoller.pollAttempt() {
                        Self.yieldEvents(for: response, into: continuation)
                        if Self.isTerminal(Self.map(response: response)) {
                            continuation.finish()
                            return
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Yield the mapped event for a poll response, preceded by a synthetic
    /// `.sessionUpdated(response)` whenever the mapped event is an action
    /// event (`.threeDSChallengeReady` / `.redirectRequired`).
    ///
    /// This guarantees the coordinator's `lastSession` is populated with
    /// the response carrying the merchant's `redirectUrl` BEFORE the action
    /// event reaches the WebView presenter. Without this, the very first
    /// poll returning `actionType=threeDsChallenge` would hand the presenter
    /// a nil `merchantReturnURL`, the policy's host-match arm would never
    /// fire, and the WebView would happily render the merchant's redirect
    /// page when the issuer ACS bounced back to it.
    ///
    /// Terminal events (`.sessionCompleted`, `.sessionFailed`) already carry
    /// the response inline so no synthetic update is needed. Native
    /// `.sessionUpdated` events are passed through unchanged.
    private static func yieldEvents(
        for response: SessionResponse,
        into continuation: AsyncThrowingStream<ChannelEvent, Error>.Continuation
    ) {
        // Production-validation logging (retained, internal-only): record the
        // server's resolved `actionType` per poll so local prod testing can
        // confirm/falsify which 3DS path the embedded flow takes —
        // `threeDsChallenge` (the interceptor `challenge_url`, which emits the
        // `challenge` postMessage the event-driven reveal keys on) vs `redirect`
        // (the hosted page, which emits none). The raw `action_type` is also in
        // the DevTools network log; this surfaces it on the lifecycle timeline.
        let mapped = map(response: response)
        switch mapped {
        case .threeDSChallengeReady, .redirectRequired:
            continuation.yield(.sessionUpdated(response))
            continuation.yield(mapped)
        case .sessionUpdated, .sessionCompleted, .sessionFailed:
            continuation.yield(mapped)
        }
    }

    private static func map(response: SessionResponse) -> ChannelEvent {
        // Terminal: status flipped to completed (the canonical success signal).
        if case .known(.completed) = response.status {
            return .sessionCompleted(response)
        }
        // 3DS challenge: intermediate. SDK must open the ACS URL, then the
        // server transitions back to readyToProcess once authentication resolves.
        // URL is validated at the mapper (scheme + lexical safety) — a hostile
        // server response with `javascript:` / `data:` / loopback / RFC1918 host
        // is rejected here, before the WebView is even constructed.
        if let url = threeDSChallengeURL(from: response) {
            if isSafeRemoteURL(url) {
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
        // Per-attempt error from the checkout-attempt path. Synthesize a
        // ProblemDetails from `nextAction.params` so callers retain SOME context
        // instead of dropping the payload (previously `.sessionFailed(nil)`).
        if case .known(.error) = response.nextAction.actionType {
            return .sessionFailed(makeProblemDetails(from: response.nextAction.params))
        }
        // Intermediate (incl. readyToProcess): the server is auto-processing
        // the payment on its own. Client just keeps polling.
        return .sessionUpdated(response)
    }

    /// Defense-in-depth filter for URLs surfaced from the server's
    /// `nextAction.params`. The 3DS WebView also runs this check before
    /// loading, but stopping the URL here means a hostile `javascript:` /
    /// `data:` / loopback payload never reaches a presented sheet at all
    /// — it surfaces as `.sessionFailed(invalid_configuration)` instead.
    private static func isSafeRemoteURL(_ url: URL) -> Bool {
        // `isUnsafeNavigation` enforces https-only + lexical IP-literal /
        // localhost rejection. A return value of `false` means safe.
        !isUnsafeNavigation(url: url)
    }

    private static func threeDSChallengeURL(from response: SessionResponse) -> URL? {
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
        // and the poll times out (PXP-5009).
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
    private static func makeProblemDetails(from params: [String: AnyCodable]?) -> ProblemDetails {
        let errorObject = params?["error"]?.value as? [String: Any]
        let title = (params?["title"]?.value as? String)
            ?? (errorObject?["type"] as? String)
        let detail = (params?["detail"]?.value as? String)
            ?? (errorObject?["detail"] as? String)
            ?? (params?["error_code"]?.value as? String)
            ?? "unknown"
        return ProblemDetails(title: title, detail: detail)
    }

    private static func isTerminal(_ event: ChannelEvent) -> Bool {
        switch event {
        case .sessionCompleted, .sessionFailed: true
        case .sessionUpdated, .threeDSChallengeReady, .redirectRequired: false
        }
    }
}
