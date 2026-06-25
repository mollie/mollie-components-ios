import Foundation
@preconcurrency import MollieCore

/// Orchestrates a single credit-card payment from tokenization through
/// (optional) 3-D Secure to a terminal `CardPaymentResult`.
///
/// Two submission paths, selected by `useCheckoutAttempts` (default `true`):
///
/// **Checkout-attempt path** (`useCheckoutAttempts = true`):
/// 1. Tokenize the PAN via `CardTokenizer`.
/// 2. `POST /client/v2/sessions/{token}/checkout-attempts` — receives a `checkoutAttemptToken`.
/// 3. Observe per-attempt state via `SessionEventConsumer.observeAttempt(sessionToken:)`.
///    Polls `GET /checkout-attempts/` (trailing slash); the `checkoutAttemptToken` is
///    baked into the poller passed to the consumer, so the lookup cannot drift.
///
/// **Legacy path** (`useCheckoutAttempts = false`):
/// 1. Tokenize the PAN via `CardTokenizer`.
/// 2. `PATCH /client/v2/sessions/{token}/details` with the pspToken.
/// 3. Observe session via `SessionEventConsumer.observe(sessionToken:)`.
///
/// Both paths: on `.threeDSChallengeReady`, delegate to the injected `ChallengePresenting`
/// and continue on `.authenticated`.
///
/// `SingleFlight` guarantees that a second `submit` call while one is
/// already in flight returns `.failed(.invalidConfiguration)` instead of
/// silently queueing.
/// Made public for demo target access; will be re-evaluated when MollieComponents umbrella ships in Phase 4.
public final class CardPaymentCoordinator: Sendable {
    private let sessionsClient: any HTTPClient
    private let tokenizer: CardTokenizer
    private let sessionEventConsumer: SessionEventConsumer
    private let challengePresenter: any ChallengePresenting
    private let challengeContainer: any ChallengeContainer
    private let sessionToken: String
    private let onSessionUpdate: (@Sendable (SessionResponse) -> Void)?
    private let singleFlight = SingleFlight()
    private let useCheckoutAttempts: Bool
    private let pollerFactory: @Sendable (_ sessionToken: String, _ checkoutAttemptToken: String) -> SessionPoller
    private let consumerFactory: @Sendable (SessionPoller) -> SessionEventConsumer

    package init(
        sessionsClient: any HTTPClient,
        tokenizerClient: any HTTPClient,
        channelsClient: any MollieChannelsClient,
        sessionToken: String,
        profileToken: String,
        testmode: Bool,
        challengePresenter: any ChallengePresenting,
        challengeContainer: any ChallengeContainer,
        pollingSchedule: PollingSchedule = .default,
        useCheckoutAttempts: Bool = true,
        onSessionUpdate: (@Sendable (SessionResponse) -> Void)? = nil
    ) {
        self.sessionsClient = sessionsClient
        tokenizer = CardTokenizer(httpClient: tokenizerClient, profileToken: profileToken, testmode: testmode)
        // Legacy path: pre-build consumer for observe(sessionToken:).
        let legacyPoller = SessionPoller(
            httpClient: sessionsClient,
            sessionToken: sessionToken,
            schedule: pollingSchedule
        )
        sessionEventConsumer = SessionEventConsumer(
            channelsClient: channelsClient,
            sessionPoller: legacyPoller
        )
        self.challengePresenter = challengePresenter
        self.challengeContainer = challengeContainer
        self.sessionToken = sessionToken
        self.onSessionUpdate = onSessionUpdate
        self.useCheckoutAttempts = useCheckoutAttempts
        // Default factories for the checkout-attempt path; built lazily at submit time.
        pollerFactory = { [sessionsClient, pollingSchedule] sToken, catToken in
            SessionPoller(
                httpClient: sessionsClient,
                sessionToken: sToken,
                checkoutAttemptToken: catToken,
                schedule: pollingSchedule
            )
        }
        consumerFactory = { [channelsClient] poller in
            SessionEventConsumer(channelsClient: channelsClient, sessionPoller: poller)
        }
    }

    public func submit(_ data: CardSubmissionData) async -> CardPaymentResult {
        do {
            return try await singleFlight.guarded {
                try await self.runSubmit(data)
            }
        } catch is CancellationError {
            // Parent task was cancelled mid-flow (host backed out, sheet
            // dismissed). Best-effort fire cancel-authentication on a
            // detached task so the backend leaves `pending_authentication`
            // and accepts the next submit. Detached because our own task
            // is cancelled — a structured call would short-circuit before
            // the HTTP request goes out.
            let token = sessionToken
            let client = sessionsClient
            Task.detached { [client, token] in
                _ = try? await client.perform(SessionEndpoint.cancelAuthentication(sessionToken: token))
            }
            return .cancelled
        } catch let error as MollieError {
            return .failed(error)
        } catch let urlError as URLError {
            // Surface networking failures with their original URLError so
            // callers (and DevTools) get the correct classification, instead
            // of mis-tagging them as invalid-configuration.
            return .failed(.network(urlError))
        } catch {
            // Genuinely-unknown runtime error: preserve it under .unknown
            // rather than fabricating an .invalidConfiguration (which means
            // "the merchant wired this wrong" — categorically different).
            return .failed(.unknown(error))
        }
    }

    /// The one logical submit. Both charging POSTs it drives — `tokenize` and
    /// `createCheckoutAttempt` — are **not auto-retried** (no server honours an
    /// inbound idempotency key, so the SDK adds none; spike #316 / Model B). A
    /// second `submit` while one is in flight is rejected by `SingleFlight`, so
    /// an in-process re-tap cannot double-charge. The `checkoutAttemptToken`
    /// minted by `createCheckoutAttempt` is the dedup anchor; on an
    /// indeterminate outcome the flow surfaces `.timeout(operation:)` and the
    /// merchant reconciles server-side. Any future idempotency key would be
    /// minted once here (one key per logical submit) and reused across HTTP
    /// attempts — never per-attempt. See decisions-log "2026-06-23 — Network
    /// idempotency model decided (spike #316 resolved)".
    private func runSubmit(_ data: CardSubmissionData) async throws -> CardPaymentResult {
        // 1. Tokenize the PAN.
        MollieLogger.log("Coordinator", "step 1: tokenizing card")
        let token: CardToken
        do {
            token = try await tokenizer.tokenize(data)
        } catch {
            // Re-throw as `.tokenizationFailed` so callers can distinguish
            // tokenizer-vs-network errors at the user-facing surface (the
            // top-level catch would otherwise mis-tag URLErrors as
            // `.network(...)` and other MollieErrors as their inner case,
            // which loses the "this happened during tokenization" signal).
            // The tokenizer already wraps validation errors in
            // `.tokenizationFailed`; pass those through untouched so callers
            // see a single, non-nested case.
            if case .tokenizationFailed = error as? MollieError {
                throw error
            }
            throw MollieError.tokenizationFailed(
                reason: error.localizedDescription,
                underlying: error
            )
        }
        MollieLogger.log("Coordinator", "step 1 done: cardToken=...\(token.value.suffix(4))")

        if useCheckoutAttempts {
            return try await runSubmitViaCheckoutAttempt(pspToken: token.value)
        } else {
            return try await runSubmitViaLegacyPatch(pspToken: token.value)
        }
    }

    private func runSubmitViaCheckoutAttempt(pspToken: String) async throws -> CardPaymentResult {
        // 2. POST /checkout-attempts — receive a checkout-attempt token.
        MollieLogger.log("Coordinator", "step 2: POST /checkout-attempts sessionToken=...\(sessionToken.suffix(4))")
        let fingerprint = await DeviceFingerprintBuilder.current()
        let body = CreateCheckoutAttemptRequestFactory.creditCard(
            pspToken: pspToken,
            fingerprint: fingerprint
        )
        let created = try await sessionsClient.perform(
            SessionEndpoint.createCheckoutAttempt(sessionToken: sessionToken, body: body)
        )
        let checkoutAttemptToken = created.checkoutAttemptToken
        MollieLogger.log("Coordinator", "step 2 done: cat=...\(checkoutAttemptToken.suffix(4))")

        // 3. Drain per-attempt events until a terminal state.
        let poller = pollerFactory(sessionToken, checkoutAttemptToken)
        let consumer = consumerFactory(poller)
        return try await drainEvents(
            stream: consumer.observeAttempt(sessionToken: sessionToken)
        )
    }

    private func runSubmitViaLegacyPatch(pspToken: String) async throws -> CardPaymentResult {
        // 2. PATCH /sessions/{token}/details with the card token.
        // The server auto-starts payment execution once it records the
        // pspToken — no further client call is required to trigger it.
        MollieLogger.log("Coordinator", "step 2: PATCH /details sessionToken=...\(sessionToken.suffix(4))")
        let fingerprint = await DeviceFingerprintBuilder.current()
        let detailsBody = SessionPatchRequest.creditCard(token: pspToken, fingerprint: fingerprint)
        _ = try await sessionsClient.perform(
            SessionEndpoint.updateDetails(sessionToken: sessionToken, body: detailsBody)
        )
        MollieLogger.log("Coordinator", "step 2 done")

        // 3. Drain session events until a terminal state.
        return try await drainEvents(stream: sessionEventConsumer.observe(sessionToken: sessionToken))
    }

    // Inherent complexity: the function is the single drainer for every
    // ChannelEvent case + the two presentation branches (challenge + redirect),
    // each with three sub-outcomes. Splitting it would scatter the presentation
    // re-entry guards across helpers and obscure the linear event flow.
    // swiftlint:disable:next cyclomatic_complexity
    private func drainEvents(stream: AsyncThrowingStream<ChannelEvent, Error>) async throws -> CardPaymentResult {
        // Full-window presentation guard: while a challenge is being shown we
        // must reject ALL subsequent .threeDSChallengeReady events, not just
        // ones that match the in-flight URL. Backends sometimes emit slightly
        // different ACS URLs (cache-busting query params, re-issued nonces)
        // for the same logical challenge — the old per-URL slot let those
        // through and re-presented the WebView mid-challenge.
        var isPresenting = false
        var lastSession: SessionResponse?
        for try await event in stream {
            switch event {
            case let .sessionCompleted(session):
                onSessionUpdate?(session)
                return .completed(session)
            case let .sessionFailed(details):
                // ChannelEvent.sessionFailed carries ProblemDetails, not a
                // SessionResponse. We surface the last observed session (if any)
                // so consumers wired to onSessionUpdate see the most recent state
                // before the failure result is returned. Reachable from the
                // checkout-attempt error path (synthesized ProblemDetails).
                if let lastSession {
                    onSessionUpdate?(lastSession)
                }
                return .failed(.sessionFailed(details))
            case let .threeDSChallengeReady(url):
                // Drop ALL re-emissions while a challenge is on screen — the
                // ACS page can take ~10s to resolve and the poller will keep
                // yielding fresh nextAction snapshots throughout.
                if isPresenting {
                    continue
                }
                isPresenting = true
                // Thread the session's `redirectUrl` (when known) into the
                // challenge presenter so the WebView's navigation policy
                // recognises the ACS bouncing back to the merchant's
                // redirect host and dismisses. Without this, the WebView
                // sits on the merchant-return page forever (e.g.
                // `https://example.com/return`). Pre-poll cases where we
                // have no session yet pass `nil`; the presenter falls back
                // to its existing behaviour.
                let challengeReturnURL = lastSession?.redirectUrl.flatMap(URL.init(string:))
                let result = await challengePresenter.present(
                    challengeURL: url,
                    returnURL: challengeReturnURL,
                    in: challengeContainer
                )
                isPresenting = false
                // After the long-await, the parent task may have been cancelled
                // (host backed out, sheet dismissed). Surface cancellation
                // before continuing the loop so callers don't see a phantom
                // completion arrive after dismissal.
                try Task.checkCancellation()
                switch result {
                case .authenticated:
                    continue
                case let .failed(reason):
                    return .failed(.threeDSFailed(reason: reason))
                case .cancelled:
                    await sendCancelAuthentication()
                    return .cancelled
                }
            case let .redirectRequired(url):
                // Server emitted actionType=redirect with a Mollie hosted page
                // URL (typically `pay.mollie.nl/payment/prepare-authentication/…`).
                // Present in a WebView and dismiss when the user lands on the
                // merchant's redirectUrl host. Dismissal does NOT mean payment
                // success — the polling stream stays open and only a
                // subsequent `.sessionCompleted` from status=completed yields
                // a successful CardPaymentResult.
                if isPresenting {
                    continue
                }
                isPresenting = true
                let returnURL = lastSession?.redirectUrl.flatMap(URL.init(string:))
                let result = await challengePresenter.presentRedirect(
                    url: url,
                    returnURL: returnURL,
                    in: challengeContainer
                )
                isPresenting = false
                try Task.checkCancellation()
                switch result {
                case .authenticated:
                    // "Presentation finished" — keep draining the stream so
                    // the next poll determines paid/failed.
                    continue
                case let .failed(reason):
                    return .failed(.threeDSFailed(reason: reason))
                case .cancelled:
                    await sendCancelAuthentication()
                    return .cancelled
                }
            case let .sessionUpdated(session):
                // No emit here — `.checkoutAttemptStateChanged` is already
                // emitted at the poll-site (SessionPoller.pollAttempt) for
                // the CAT branch; the legacy branch has no per-attempt event
                // by design.
                lastSession = session
                onSessionUpdate?(session)
                continue
            }
        }

        // Stream finished without a terminal event — treat as timeout so the
        // caller surfaces a retryable error rather than hanging. Always fire
        // cancel-authentication so the backend leaves `pending_authentication`
        // and accepts a fresh `POST /checkout-attempts` on the next submit —
        // otherwise subsequent submits will be rejected by the server.
        await sendCancelAuthentication()
        return .failed(.timeout(operation: "card-payment"))
    }

    /// PATCH /sessions/{token}/cancel-authentication so the backend can leave
    /// `pending_authentication` and accept a fresh `POST /checkout-attempts`
    /// on the next submit. We always return `.cancelled` to the caller even
    /// if this call fails — the user did cancel, and lying about that would
    /// be worse than the merchant having to surface the next-attempt error
    /// from the backend. Failures are reported via the internal debug hook so
    /// DevTools and merchant logging can spot stuck sessions.
    ///
    /// Complexity comes from the exhaustive switch on every `MollieError` case
    /// so DevTools sees a stable per-case token instead of `String(describing:)`
    /// noise.
    private func sendCancelAuthentication() async { // swiftlint:disable:this cyclomatic_complexity
        _ = try? await sessionsClient.perform(
            SessionEndpoint.cancelAuthentication(sessionToken: sessionToken)
        )
    }
}

#if canImport(UIKit) && canImport(WebKit)
    import UIKit

    public extension CardPaymentCoordinator {
        /// Convenience init that constructs the platform `ThreeDSCoordinator`
        /// for hosts that already have a UIKit navigation container.
        /// Made public for demo target access; will be re-evaluated when MollieComponents umbrella ships in Phase 4.
        convenience init(
            sessionsClient: any HTTPClient,
            tokenizerClient: any HTTPClient,
            channelsClient: any MollieChannelsClient,
            sessionToken: String,
            profileToken: String,
            testmode: Bool,
            challengeContainer: UINavigationChallengeContainer,
            pollingTimeoutSeconds: TimeInterval = 30,
            useCheckoutAttempts: Bool = true,
            onSessionUpdate: (@Sendable (SessionResponse) -> Void)? = nil
        ) {
            // Pass `.infinity` for `pollingTimeoutSeconds` to disable the
            // session-polling timeout entirely — useful when an upstream UI
            // (e.g. a Stop button) provides its own cancellation control.
            let schedule = PollingSchedule(
                intervals: PollingSchedule.default.intervals,
                totalBudget: pollingTimeoutSeconds
            )
            self.init(
                sessionsClient: sessionsClient,
                tokenizerClient: tokenizerClient,
                channelsClient: channelsClient,
                sessionToken: sessionToken,
                profileToken: profileToken,
                testmode: testmode,
                challengePresenter: ThreeDSCoordinator(),
                challengeContainer: challengeContainer,
                pollingSchedule: schedule,
                useCheckoutAttempts: useCheckoutAttempts,
                onSessionUpdate: onSessionUpdate
            )
        }

        /// Convenience init for modal hosts (e.g. the Phase 4 payment sheet),
        /// which present the 3DS WebView from a `presentingViewController`
        /// instead of pushing onto a nav stack.
        convenience init(
            sessionsClient: any HTTPClient,
            tokenizerClient: any HTTPClient,
            channelsClient: any MollieChannelsClient,
            sessionToken: String,
            profileToken: String,
            testmode: Bool,
            challengeContainer: ViewControllerChallengeContainer,
            pollingTimeoutSeconds: TimeInterval = 30,
            useCheckoutAttempts: Bool = true,
            onSessionUpdate: (@Sendable (SessionResponse) -> Void)? = nil
        ) {
            let schedule = PollingSchedule(
                intervals: PollingSchedule.default.intervals,
                totalBudget: pollingTimeoutSeconds
            )
            self.init(
                sessionsClient: sessionsClient,
                tokenizerClient: tokenizerClient,
                channelsClient: channelsClient,
                sessionToken: sessionToken,
                profileToken: profileToken,
                testmode: testmode,
                challengePresenter: ThreeDSCoordinator(),
                challengeContainer: challengeContainer,
                pollingSchedule: schedule,
                useCheckoutAttempts: useCheckoutAttempts,
                onSessionUpdate: onSessionUpdate
            )
        }
    }
#endif
