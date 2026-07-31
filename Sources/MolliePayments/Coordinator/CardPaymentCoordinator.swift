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
/// Made public for demo target access; will be re-evaluated once the `MollieComponents` umbrella target ships.
public final class CardPaymentCoordinator: Sendable {
    private let sessionsClient: any HTTPClient
    private let tokenizer: CardTokenizer
    private let sessionEventConsumer: SessionEventConsumer
    private let challengePresenter: any ChallengePresenting
    private let challengeContainer: any ChallengeContainer
    private let sessionToken: String
    private let onSessionUpdate: (@Sendable (SessionResponse) -> Void)?
    /// Widened sibling of `onSessionUpdate`: fires for every non-terminal
    /// `ChannelEvent` tick observed while draining (session snapshots AND
    /// 3DS-challenge/redirect presentation), so a caller building an
    /// observable session-shaped stream (see `MollieCheckoutEvent`) can
    /// forward mid-flow progress without re-deriving it from
    /// `onSessionUpdate`'s narrower `SessionResponse`-only payload. Never
    /// fires for the two terminal `ChannelEvent` cases — those are left to
    /// the caller to derive from `submit(_:)`'s terminal `CardPaymentResult`
    /// return value, so a single attempt's terminal event is never reported
    /// twice.
    private let onEvent: (@Sendable (ChannelEvent) -> Void)?
    private let singleFlight = SingleFlight()
    private let useCheckoutAttempts: Bool
    private let pollerFactory: @Sendable (_ sessionToken: String, _ checkoutAttemptToken: String) -> SessionPoller
    private let consumerFactory: @Sendable (SessionPoller) -> SessionEventConsumer
    /// Awaited once per submit, right after tokenization and before the
    /// checkout-attempt POST, so a merchant can inject `MollieCustomerDetails`
    /// or veto the submission outright. A throw aborts the submission,
    /// triggers `sendCancelAuthentication()`, and surfaces as a terminal
    /// `.failed(.invalidConfiguration(field: "beforeSubmit", ...))`.
    private let beforeSubmit: (@Sendable () async throws -> MollieCustomerDetails?)?
    /// Budget for the concurrent session-completion poll on the checkout-attempt
    /// path (see `SessionEventConsumer.observeCardPayment`). Spans an interactive
    /// 3DS challenge so a paid+authorized session is observed via `GET /sessions`
    /// even when the attempt projection stalls. A non-positive value disables the
    /// concurrent poll (used by tests pinning attempt-only behaviour).
    private let challengeCompletionBudget: TimeInterval

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
        onSessionUpdate: (@Sendable (SessionResponse) -> Void)? = nil,
        onEvent: (@Sendable (ChannelEvent) -> Void)? = nil,
        beforeSubmit: (@Sendable () async throws -> MollieCustomerDetails?)? = nil,
        challengeCompletionBudget: TimeInterval = SessionEventConsumer.defaultChallengeCompletionBudget
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
        self.onEvent = onEvent
        self.beforeSubmit = beforeSubmit
        self.challengeCompletionBudget = challengeCompletionBudget
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
    /// inbound idempotency key, so the SDK adds none; Model B). A
    /// second `submit` while one is in flight is rejected by `SingleFlight`, so
    /// an in-process re-tap cannot double-charge. The `checkoutAttemptToken`
    /// minted by `createCheckoutAttempt` is the dedup anchor; on an
    /// indeterminate outcome the flow surfaces `.timeout(operation:)` and the
    /// merchant reconciles server-side. Any future idempotency key would be
    /// minted once here (one key per logical submit) and reused across HTTP
    /// attempts — never per-attempt, per the 2026-06-23 network-idempotency
    /// design decision (Model B, token-as-anchor).
    private func runSubmit(_ data: CardSubmissionData) async throws -> CardPaymentResult {
        // Local, mutable copy so we can best-effort wipe the PAN/CVC once the
        // card token is in hand (see `workingData.zero()` below). The caller
        // still owns its own copy.
        var workingData = data
        // 1. Tokenize the PAN.
        MollieLogger.log("Coordinator", "step 1: tokenizing card")
        let token: CardToken
        do {
            token = try await tokenizer.tokenize(workingData)
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

        // The PAN/CVC are no longer needed once we hold the card token.
        // Best-effort drop them from our working copy to shrink the in-memory
        // window (this is "drop the reference," not guaranteed scrubbing — see
        // CardSubmissionData.zero()).
        workingData.zero()

        // 1b. Merchant hook: let the caller inject customer details (or veto
        // the submission) now that a token is in hand but before anything is
        // charged. A throw here aborts the submission before the
        // checkout-attempt POST goes out.
        let customerDetails: MollieCustomerDetails?
        if let beforeSubmit {
            do {
                customerDetails = try await beforeSubmit()
            } catch {
                // Preserve the original error before it's flattened into a
                // `localizedDescription` string on the public `MollieError`:
                // the merchant's hook may throw a typed domain error (e.g. a
                // network failure fetching billing details) whose type/object
                // is otherwise lost from every diagnostic surface. The public
                // error shape stays unchanged.
                MollieLogger.log("beforeSubmit", "hook threw: \(error)")
                await sendCancelAuthentication()
                throw MollieError.invalidConfiguration(
                    field: "beforeSubmit",
                    reason: "beforeSubmit hook threw: \(error.localizedDescription)"
                )
            }
        } else {
            customerDetails = nil
        }

        if useCheckoutAttempts {
            return try await runSubmitViaCheckoutAttempt(pspToken: token.value, customerDetails: customerDetails)
        } else {
            return try await runSubmitViaLegacyPatch(pspToken: token.value)
        }
    }

    private func runSubmitViaCheckoutAttempt(
        pspToken: String,
        customerDetails: MollieCustomerDetails?
    ) async throws -> CardPaymentResult {
        // 2. POST /checkout-attempts — receive a checkout-attempt token.
        MollieLogger.log("Coordinator", "step 2: POST /checkout-attempts sessionToken=...\(sessionToken.suffix(4))")
        let fingerprint = await DeviceFingerprintBuilder.current()
        let body = CreateCheckoutAttemptRequestFactory.creditCard(
            pspToken: pspToken,
            fingerprint: fingerprint,
            customerDetails: customerDetails
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
            stream: consumer.observeCardPayment(
                sessionToken: sessionToken,
                challengeCompletionBudget: challengeCompletionBudget
            )
        )
    }

    private func runSubmitViaLegacyPatch(pspToken: String) async throws -> CardPaymentResult {
        // 2. PATCH /sessions/{token}/details with the card token.
        // The server auto-starts payment execution once it records the
        // pspToken — no further client call is required to trigger it.
        MollieLogger.log("Coordinator", "step 2: PATCH /details sessionToken=...\(sessionToken.suffix(4))")
        let fingerprint = await DeviceFingerprintBuilder.current()
        let detailsBody = SessionPatchRequest.creditCard(token: pspToken, fingerprint: fingerprint)
        let patched = try await sessionsClient.perform(
            SessionEndpoint.updateDetails(sessionToken: sessionToken, body: detailsBody)
        )
        MollieLogger.log("Coordinator", "step 2 done")

        // 3. Drain session events until a terminal state. Seed the drain with
        // the PATCH response: the merchant's `redirectUrl` is returned HERE,
        // not on the later 3DS-challenge poll snapshot, so without this seed
        // the challenge presenter would receive `nil` and its host-match
        // dismissal could never fire (see `drainEvents`' `initialSession`).
        return try await drainEvents(
            stream: sessionEventConsumer.observe(sessionToken: sessionToken),
            initialSession: patched
        )
    }

    // Inherent complexity: the function is the single drainer for every
    // ChannelEvent case + the two presentation branches (challenge + redirect),
    // each with three sub-outcomes. Splitting it would scatter the presentation
    // re-entry guards across helpers and obscure the linear event flow.
    // swiftlint:disable:next cyclomatic_complexity
    private func drainEvents(
        stream: AsyncThrowingStream<ChannelEvent, Error>,
        initialSession: SessionResponse? = nil
    ) async throws -> CardPaymentResult {
        // A frictionless hosted 3DS page (pay.mollie.nl/payment/
        // prepare-authentication/…) completes the payment server-side
        // without ever navigating to the return URL or firing the
        // `mollie-interceptor` postMessage, so `present`/`presentRedirect`
        // never resolve on their own — even after the poller has already
        // observed the terminal `.sessionCompleted`/`.sessionFailed`. A plain
        // `for try await` loop would stay parked on the presenter await and
        // never see those events.
        //
        // We therefore never hand the raw stream's iterator itself to a
        // task-group race: cancelling a task suspended inside
        // `AsyncThrowingStream.AsyncIterator.next()` terminates the stream's
        // shared underlying storage for EVERY consumer, including copies
        // that were never themselves cancelled (verified empirically).
        // Racing the raw iterator directly would therefore
        // permanently kill the poll stream the first time a challenge
        // presentation won the race, breaking the very next `.next()` call
        // the outer loop makes. Instead, a single, never-cancelled `pump`
        // task owns the raw iterator for the whole lifetime of this
        // function and forwards events into `EventQueue`, a small
        // cancellation-safe relay: cancelling a waiter on the queue only
        // resolves that one wait, never the queue itself, so
        // `raceChallengePresentation` can freely cancel the losing side of
        // its race without endangering subsequent consumption.
        let queue = EventQueue()
        let pump = Task {
            var rawIterator = stream.makeAsyncIterator()
            do {
                while let event = try await rawIterator.next() {
                    queue.push(event)
                }
                queue.finish()
            } catch {
                queue.finish(.failure(error))
            }
        }
        defer { pump.cancel() }

        // `lastSession` tracks the latest observed snapshot. `merchantReturnURL`
        // is the STICKY merchant `redirectUrl`: once any session reports one
        // (seeded here from the legacy PATCH response) it is retained even if a
        // later snapshot — e.g. the minimal 3DS-challenge poll — omits it, so
        // the challenge/redirect presenter always receives the return URL its
        // host-match dismissal needs.
        var lastSession: SessionResponse? = initialSession
        var merchantReturnURL: URL? = initialSession?.redirectUrl.flatMap(URL.init(string:))
        while let event = try await queue.next() {
            switch event {
            case let .sessionCompleted(session):
                return handleSessionCompleted(session)
            case let .sessionFailed(details):
                return handleSessionFailed(details, lastSession: lastSession)
            case let .threeDSChallengeReady(url):
                // Thread the session's `redirectUrl` (when known) into the
                // challenge presenter so the WebView's navigation policy
                // recognises the ACS bouncing back to the merchant's
                // redirect host and dismisses. Without this, the WebView
                // sits on the merchant-return page forever (e.g.
                // `https://example.com/return`). Pre-poll cases where we
                // have no session yet pass `nil`; the presenter falls back
                // to its existing behaviour.
                onEvent?(.threeDSChallengeReady(url))
                let challengeReturnURL = merchantReturnURL
                let sessionBox = SessionBox(lastSession)
                let outcome = try await raceChallengePresentation(
                    queue: queue,
                    sessionBox: sessionBox
                ) { [challengePresenter, challengeContainer] in
                    await challengePresenter.present(
                        challengeURL: url,
                        returnURL: challengeReturnURL,
                        in: challengeContainer
                    )
                }
                lastSession = sessionBox.get()
                if let refreshed = lastSession?.redirectUrl.flatMap(URL.init(string:)) {
                    merchantReturnURL = refreshed
                }
                if let result = try await handleChallengeRaceOutcome(outcome, lastSession: lastSession) {
                    return result
                }
            case let .redirectRequired(url):
                // Server emitted actionType=redirect with a Mollie hosted page
                // URL (typically `pay.mollie.nl/payment/prepare-authentication/…`).
                // Present in a WebView and dismiss when the user lands on the
                // merchant's redirectUrl host. Dismissal does NOT mean payment
                // success — the polling stream stays open and only a
                // subsequent `.sessionCompleted` from status=completed yields
                // a successful CardPaymentResult.
                onEvent?(.redirectRequired(url))
                let returnURL = merchantReturnURL
                let sessionBox = SessionBox(lastSession)
                let outcome = try await raceChallengePresentation(
                    queue: queue,
                    sessionBox: sessionBox
                ) { [challengePresenter, challengeContainer] in
                    await challengePresenter.presentRedirect(
                        url: url,
                        returnURL: returnURL,
                        in: challengeContainer
                    )
                }
                lastSession = sessionBox.get()
                if let refreshed = lastSession?.redirectUrl.flatMap(URL.init(string:)) {
                    merchantReturnURL = refreshed
                }
                if let result = try await handleChallengeRaceOutcome(outcome, lastSession: lastSession) {
                    return result
                }
            case let .sessionUpdated(session):
                // No emit here — `.checkoutAttemptStateChanged` is already
                // emitted at the poll-site (SessionPoller.pollAttempt) for
                // the CAT branch; the legacy branch has no per-attempt event
                // by design.
                lastSession = session
                if let redirect = session.redirectUrl.flatMap(URL.init(string:)) {
                    merchantReturnURL = redirect
                }
                onSessionUpdate?(session)
                onEvent?(.sessionUpdated(session))
                continue
            case let .attemptFailed(details):
                // Retryable soft-decline: THIS attempt is
                // done (the polled attempt/session has already reset
                // server-side), so return to the caller instead of
                // continuing to poll a dead attempt token. See
                // `handleAttemptFailed` for why this does not tear down the
                // session the way `.sessionFailed` does.
                return handleAttemptFailed(details, lastSession: lastSession)
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

    private func handleSessionCompleted(_ session: SessionResponse) -> CardPaymentResult {
        onSessionUpdate?(session)
        return .completed(session)
    }

    private func handleSessionFailed(_ details: ProblemDetails?, lastSession: SessionResponse?) -> CardPaymentResult {
        // ChannelEvent.sessionFailed carries ProblemDetails, not a
        // SessionResponse. We surface the last observed session (if any)
        // so consumers wired to onSessionUpdate see the most recent state
        // before the failure result is returned. Reachable from the
        // checkout-attempt error path (synthesized ProblemDetails).
        if let lastSession {
            onSessionUpdate?(lastSession)
        }
        return .failed(.sessionFailed(details))
    }

    /// Handles a retryable soft-decline
    /// (`ChannelEvent.attemptFailed`). Unlike `handleSessionFailed`, this
    /// does NOT call `sendCancelAuthentication()` — the server has already
    /// reset the session to `CREATED` itself (that's what makes the decline
    /// "retryable" in the first place), so there is nothing left to clean
    /// up server-side. A fresh `submit(_:)` call on the same
    /// `CardPaymentCoordinator`/session is accepted immediately.
    private func handleAttemptFailed(
        _ details: ProblemDetails?,
        lastSession: SessionResponse?
    ) -> CardPaymentResult {
        if let lastSession {
            onSessionUpdate?(lastSession)
        }
        return .attemptFailed(details)
    }

    /// Lock-guarded holder for the session snapshot the draining child of
    /// `raceChallengePresentation` observes via `.sessionUpdated` while the
    /// race is in flight. `CardPaymentCoordinator` is a plain `Sendable`
    /// class with only `let` properties, and `drainEvents`' `lastSession` is
    /// a local `var` — it cannot be captured mutably by the `@Sendable`
    /// task-group child closure, so the update is threaded through this box
    /// instead and read back by the caller once the race concludes.
    private final class SessionBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: SessionResponse?

        init(_ value: SessionResponse?) {
            self.value = value
        }

        func get() -> SessionResponse? {
            lock.withLock { value }
        }

        func set(_ newValue: SessionResponse) {
            lock.withLock { value = newValue }
        }
    }

    /// Cancellation-safe single-consumer relay sitting between the raw poll
    /// stream and everything in `drainEvents` that needs to observe it.
    ///
    /// `AsyncThrowingStream.AsyncIterator` terminates its entire shared
    /// storage when a task suspended inside `.next()` is cancelled — even
    /// for iterator copies that were never themselves cancelled (verified
    /// empirically). `raceChallengePresentation`
    /// needs to cancel the losing side of its race, so racing the raw
    /// iterator directly would permanently kill the poll stream the first
    /// time a presentation won. `EventQueue` decouples "pull from the raw
    /// stream" (done exactly once, by the never-cancelled pump task in
    /// `drainEvents`) from "wait for the next event" (what actually gets
    /// raced): cancelling a `next()` waiter resolves only that one call —
    /// the queue's buffer and finished state are untouched, so a fresh call
    /// afterwards still observes every subsequent push.
    private final class EventQueue: @unchecked Sendable {
        private let lock = NSLock()
        private var buffered: [ChannelEvent] = []
        private var finishedWith: Result<Void, Error>?
        private var waiter: CheckedContinuation<ChannelEvent?, Error>?
        private var cancelledBeforeWaiterStored = false

        func push(_ event: ChannelEvent) {
            lock.lock()
            guard let waiter else {
                buffered.append(event)
                lock.unlock()
                return
            }
            self.waiter = nil
            lock.unlock()
            waiter.resume(returning: event)
        }

        func finish(_ result: Result<Void, Error> = .success(())) {
            lock.lock()
            finishedWith = result
            guard let waiter else {
                lock.unlock()
                return
            }
            self.waiter = nil
            lock.unlock()
            switch result {
            case .success:
                waiter.resume(returning: nil)
            case let .failure(error):
                waiter.resume(throwing: error)
            }
        }

        /// Waits for the next event. Safe to cancel: cancellation resolves
        /// only THIS call (with `CancellationError`) and never marks the
        /// queue itself finished.
        func next() async throws -> ChannelEvent? {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ChannelEvent?, Error>) in
                    lock.lock()
                    if cancelledBeforeWaiterStored {
                        cancelledBeforeWaiterStored = false
                        lock.unlock()
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    if !buffered.isEmpty {
                        let event = buffered.removeFirst()
                        lock.unlock()
                        continuation.resume(returning: event)
                        return
                    }
                    if let finishedWith {
                        lock.unlock()
                        switch finishedWith {
                        case .success:
                            continuation.resume(returning: nil)
                        case let .failure(error):
                            continuation.resume(throwing: error)
                        }
                        return
                    }
                    waiter = continuation
                    lock.unlock()
                }
            } onCancel: {
                lock.lock()
                guard let pending = waiter else {
                    // Task was already cancelled before the continuation was
                    // stored — flag it so the operation closure above
                    // resumes immediately once it runs instead of parking a
                    // waiter that will never be woken.
                    cancelledBeforeWaiterStored = true
                    lock.unlock()
                    return
                }
                waiter = nil
                lock.unlock()
                pending.resume(throwing: CancellationError())
            }
        }
    }

    /// Outcome of racing a challenge/redirect presentation against continued
    /// poll-stream draining. Carries only `Sendable` payloads extracted from
    /// `ChannelEvent` (which is itself not `Sendable`) so it can cross the
    /// `withThrowingTaskGroup` boundary as the child tasks' result type.
    private enum ChallengeRaceOutcome {
        case presented(ThreeDSResult)
        case sessionCompleted(SessionResponse)
        case sessionFailed(ProblemDetails?)
        /// A retryable soft-decline arrived while a
        /// challenge/redirect presentation was still in flight (e.g. the
        /// poller observes the server-side reset before the WebView
        /// resolves). Same treatment as `sessionFailed` for the purposes of
        /// this race — the stranded presenter must be dismissed — but maps
        /// to `CardPaymentResult.attemptFailed` rather than `.failed`.
        case attemptFailed(ProblemDetails?)
        case streamEnded
    }

    /// Races a challenge/redirect presentation against continued poll-stream
    /// draining, both reading from the shared `EventQueue` so
    /// cancelling the losing side never disturbs the underlying poll stream
    /// (see `EventQueue`'s doc comment for why the raw stream iterator
    /// cannot be raced directly).
    ///
    /// Whichever finishes first wins:
    ///  - the presenter resolves on its own (normal path) — the drain child
    ///    is cancelled; its in-flight `queue.next()` wait resolves with
    ///    `CancellationError` immediately and the queue is left intact for
    ///    the outer loop's next call.
    ///  - a terminal poll event (or stream exhaustion) arrives first — the
    ///    presenter is still stranded (frictionless hosted 3DS never
    ///    resolves it), so we force it down via `dismiss()` before returning;
    ///    cancelling alone would not resolve its checked continuation.
    private func raceChallengePresentation( // swiftlint:disable:this cyclomatic_complexity
        queue: EventQueue,
        sessionBox: SessionBox,
        presentation: @escaping @Sendable () async -> ThreeDSResult
    ) async throws -> ChallengeRaceOutcome {
        try await withThrowingTaskGroup(of: ChallengeRaceOutcome.self) { group in
            group.addTask {
                await .presented(presentation())
            }
            group.addTask { [onSessionUpdate] in
                while let event = try await queue.next() {
                    switch event {
                    case let .sessionCompleted(session):
                        return .sessionCompleted(session)
                    case let .sessionFailed(details):
                        return .sessionFailed(details)
                    case let .sessionUpdated(session):
                        sessionBox.set(session)
                        onSessionUpdate?(session)
                    case .threeDSChallengeReady, .redirectRequired:
                        // Full-window presentation guard: drop ALL
                        // re-emissions while this presentation is in flight,
                        // not just ones matching the in-flight URL —
                        // backends keep emitting fresh nextAction snapshots
                        // (cache-busting params, re-issued nonces) for the
                        // same logical challenge throughout.
                        continue
                    case let .attemptFailed(details):
                        // Retryable soft-decline arriving
                        // mid-race (e.g. a poll tick observes the server-side
                        // reset while the challenge/redirect presenter is
                        // still on screen): the attempt is dead, so stop
                        // racing and let the outer switch dismiss the
                        // stranded presenter.
                        return .attemptFailed(details)
                    }
                }
                return .streamEnded
            }

            guard let first = try await group.next() else {
                group.cancelAll()
                return .streamEnded
            }
            switch first {
            case .presented:
                group.cancelAll()
            case .sessionCompleted, .sessionFailed, .attemptFailed, .streamEnded:
                await self.challengePresenter.dismiss()
                group.cancelAll()
            }
            // Drain the loser so this scope doesn't rethrow a spurious
            // CancellationError from it on exit.
            while true {
                do {
                    guard try await group.next() != nil else { break }
                } catch {
                    continue
                }
            }
            return first
        }
    }

    /// Maps a `raceChallengePresentation` outcome to either a terminal
    /// `CardPaymentResult` (return it) or `nil` (keep draining the outer
    /// loop).
    private func handleChallengeRaceOutcome(
        _ outcome: ChallengeRaceOutcome,
        lastSession: SessionResponse?
    ) async throws -> CardPaymentResult? {
        switch outcome {
        case let .presented(result):
            // After the long-await, the parent task may have been cancelled
            // (host backed out, sheet dismissed). Surface cancellation
            // before continuing the loop so callers don't see a phantom
            // completion arrive after dismissal.
            try Task.checkCancellation()
            switch result {
            case .authenticated:
                return nil
            case let .failed(reason):
                return .failed(.threeDSFailed(reason: reason))
            case .cancelled:
                await sendCancelAuthentication()
                return .cancelled
            }
        case let .sessionCompleted(session):
            return handleSessionCompleted(session)
        case let .sessionFailed(details):
            return handleSessionFailed(details, lastSession: lastSession)
        case let .attemptFailed(details):
            return handleAttemptFailed(details, lastSession: lastSession)
        case .streamEnded:
            // The poll stream finished before the presenter resolved on its
            // own; `dismiss()` already ran. Fall through to the outer loop,
            // whose next `iterator.next()` call will also see the stream
            // has ended and hit the "stream finished without terminal"
            // handling at the bottom of `drainEvents`.
            return nil
        }
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
        /// Made public for demo target access; will be re-evaluated once the `MollieComponents` umbrella target ships.
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
            onSessionUpdate: (@Sendable (SessionResponse) -> Void)? = nil,
            onEvent: (@Sendable (ChannelEvent) -> Void)? = nil,
            beforeSubmit: (@Sendable () async throws -> MollieCustomerDetails?)? = nil,
            locale: Locale = .current
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
                challengePresenter: ThreeDSCoordinator(locale: locale),
                challengeContainer: challengeContainer,
                pollingSchedule: schedule,
                useCheckoutAttempts: useCheckoutAttempts,
                onSessionUpdate: onSessionUpdate,
                onEvent: onEvent,
                beforeSubmit: beforeSubmit
            )
        }

        /// Convenience init for modal hosts (e.g. the payment sheet),
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
            onSessionUpdate: (@Sendable (SessionResponse) -> Void)? = nil,
            onEvent: (@Sendable (ChannelEvent) -> Void)? = nil,
            beforeSubmit: (@Sendable () async throws -> MollieCustomerDetails?)? = nil,
            locale: Locale = .current
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
                challengePresenter: ThreeDSCoordinator(locale: locale),
                challengeContainer: challengeContainer,
                pollingSchedule: schedule,
                useCheckoutAttempts: useCheckoutAttempts,
                onSessionUpdate: onSessionUpdate,
                onEvent: onEvent,
                beforeSubmit: beforeSubmit
            )
        }
    }
#endif
