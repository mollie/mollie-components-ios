#if canImport(UIKit)
    import Foundation
    @preconcurrency import MollieCore
    @preconcurrency import MolliePayments
    import MolliePaymentsUI
    import UIKit

    /// Neutral home for the card-checkout logic shared between
    /// `MollieCheckout.presentCard(from:)` (UIKit modal) and
    /// `MollieCardComponent` (SwiftUI embed): client-token decode, snapshot
    /// validation/parsing, the tokenise + 3DS + poll submit loop, engine-result
    /// mapping, channels-client resolution, and session-status formatting.
    ///
    /// Neither presentation path owns this logic — both call through here so
    /// they stay in lockstep without duplicating the `CardPaymentCoordinator`
    /// construction and session-emit bookkeeping.
    enum CardCheckoutRunner {
        /// Pure decode path, exposed for unit-test access without UIKit.
        static func decode(clientToken: String) -> Result<ClientToken, MollieError> {
            do {
                return try .success(ClientToken.decode(from: clientToken))
            } catch let error as MollieError {
                return .failure(error)
            } catch {
                return .failure(.invalidClientToken(reason: error.localizedDescription))
            }
        }

        /// Validate the snapshot (the form has already done this, but
        /// re-running it here is cheap defense in depth — any future caller
        /// that builds a snapshot bypassing the form still gets a typed
        /// failure) and convert it to the engine's `CardSubmissionData`.
        static func parse(snapshot: CardFormSnapshot) -> Result<CardSubmissionData, MollieError> {
            if let error = CardFormValidator.validate(snapshot: snapshot) {
                return .failure(.invalidConfiguration(field: error.field, reason: error.userMessage))
            }
            // ExpiryParser ran inside the validator and reported success;
            // re-running it here is the cheapest way to recover the typed
            // month/year without threading a Parsed value out of the
            // validator. A failure here means the validator and parser
            // disagree, which would be a bug — fall back to a typed error
            // rather than crashing.
            guard case let .success(parsed) = ExpiryParser.parse(snapshot.expiry) else {
                return .failure(.invalidConfiguration(field: "expiry", reason: "validator/parser disagreement"))
            }
            return .success(CardSubmissionData(
                cardholderName: snapshot.cardholderName,
                cardNumber: snapshot.cardNumber.filter { !$0.isWhitespace },
                expiryMonth: parsed.month,
                expiryYear: parsed.year,
                cvc: snapshot.cvc.filter { !$0.isWhitespace }
            ))
        }

        /// Shared submit path for both the modal (`MollieCheckout.presentCard`)
        /// and embed (`MollieCardComponent`) flows: builds the
        /// `CardPaymentCoordinator` (sessions/tokenizer/channels clients, 3DS
        /// challenge container anchored on `presentingViewController`),
        /// awaits its terminal result, and maps it onto the
        /// `MolliePaymentResult`.
        ///
        /// The two flows differ only in how they obtain
        /// `presentingViewController` (a `UINavigationController` for the
        /// modal, the active scene's root VC for the embed) and in the typed
        /// error they surface when that VC isn't available — both handled by
        /// the caller before this is reached.
        @MainActor
        static func submit( // swiftlint:disable:this function_parameter_count
            _ submission: CardSubmissionData,
            clientToken: ClientToken,
            rawClientToken: String,
            endpoints: MollieEndpoints,
            presentingViewController: UIViewController,
            checkoutEventSink: (@Sendable (MollieCheckoutEvent) -> Void)?,
            beforeSubmit: (@Sendable () async throws -> MollieCustomerDetails?)?
        ) async -> MolliePaymentResult {
            let container = ViewControllerChallengeContainer(presentingViewController: presentingViewController)
            // Capture the most-recently observed session so we can surface its
            // real status on the timeline instead of the placeholder we used
            // to emit before any network call had happened. `onSessionUpdate`
            // fires on every poller tick and on terminal completion, so this
            // closes around the freshest snapshot we have when submit returns.
            let sessionToken = clientToken.sessionToken
            let coordinator = CardPaymentCoordinator(
                sessionsClient: SessionClient(
                    baseURL: endpoints.sessionsBaseURL,
                    clientAccessToken: rawClientToken,
                    session: endpoints.urlSession
                ),
                tokenizerClient: TokenizerClient(
                    baseURL: endpoints.tokenizerBaseURL,
                    session: endpoints.urlSession
                ),
                channelsClient: makeChannelsClient(clientToken: clientToken),
                sessionToken: sessionToken,
                profileToken: clientToken.profileToken,
                testmode: clientToken.testmode,
                challengeContainer: container,
                onSessionUpdate: { session in
                    _ = session
                },
                onEvent: { event in
                    guard let checkoutEventSink,
                          let mapped = mapNonTerminalEvent(event)
                    else { return }
                    checkoutEventSink(mapped)
                },
                beforeSubmit: beforeSubmit
            )
            let cardResult = await coordinator.submit(submission)
            if case .attemptFailed = cardResult {
                // A retryable soft decline has no
                // shape in the deprecated `MolliePaymentResult` this function
                // returns (see `map(cardResult:)` below, which folds it into
                // `.failed`) — push the real, non-terminal `.attemptFailed`
                // event through the sink so callers watching the checkout's
                // event stream can react to the soft decline. The embed path
                // (`EmbeddedFormBridge`) uses this to reset the form for a
                // retry instead of treating the attempt as the session's end.
                checkoutEventSink?(mapFinalEvent(cardResult: cardResult))
            }
            return map(cardResult: cardResult)
        }

        /// Map the engine's `CardPaymentResult` onto the deprecated,
        /// merchant-facing `MolliePaymentResult` — derived from
        /// `mapFinalEvent(cardResult:)` so there is exactly one place that
        /// decides what a terminal `CardPaymentResult` means.
        static func map(cardResult: CardPaymentResult) -> MolliePaymentResult {
            MolliePaymentResult(checkoutEvent: mapFinalEvent(cardResult: cardResult))
        }

        /// Map the engine's terminal `CardPaymentResult` onto the
        /// session-shaped `MollieCheckoutEvent`. The completed
        /// `SessionResponse` carries `sessionToken` and `paymentAmount` —
        /// that's the minimum the merchant needs to reconcile against their
        /// backend. Richer fields (payment id, method, metadata) become
        /// available once the Sessions Service surfaces them on the
        /// completed event.
        static func mapFinalEvent(cardResult: CardPaymentResult) -> MollieCheckoutEvent {
            switch cardResult {
            case let .completed(session):
                .completed(MolliePayment(
                    sessionToken: session.sessionToken,
                    amount: session.paymentAmount.value,
                    currency: session.paymentAmount.currency
                ))
            case let .failed(error):
                // Terminal / non-reset declines land here; a retryable soft
                // decline (`NextAction .reset`) routes to `.attemptFailed`
                // instead — see the `.attemptFailed` case below.
                .failed(error)
            case .cancelled:
                .cancelled
            case let .attemptFailed(details):
                // This ONE submit attempt ended in
                // a retryable soft decline (see `CardPaymentResult
                // .attemptFailed`'s doc comment) — surface the non-terminal
                // `.attemptFailed` rather than folding it into a terminal
                // `.failed`. `retryable` is always `true` here: only the
                // retryable branch of `CardPaymentCoordinator.submit`
                // produces `CardPaymentResult.attemptFailed` (see
                // `handleAttemptFailed`) — a genuinely terminal decline
                // surfaces as `.failed` instead.
                .attemptFailed(retryable: true, error: .sessionFailed(details))
            }
        }

        /// Map the `MolliePaymentResult` (the shape every exit
        /// path of the modal/embed submit flows already funnels into) onto
        /// `MollieCheckoutEvent`. This is the reverse of
        /// `MolliePaymentResult.init(checkoutEvent:)` and is lossless for the
        /// three cases both types share. `MollieCheckout` calls this exactly
        /// once per attempt — after `presentCard`'s modal-coordinator call
        /// returns, and inside `makeCardComponent`'s wrapped `onResult` —
        /// because those are the true single choke points across every exit
        /// path (network outcome, invalid snapshot, cancel, unattached-host
        /// guard, decode failure); no internal submit path sees all of them.
        static func mapEvent(from result: MolliePaymentResult) -> MollieCheckoutEvent {
            switch result {
            case let .completed(payment):
                .completed(payment)
            case let .failed(error):
                .failed(error)
            case .cancelled:
                .cancelled
            }
        }

        /// Map a non-terminal `ChannelEvent` tick (observed mid-attempt, via
        /// `CardPaymentCoordinator`'s `onEvent` hook) onto the corresponding
        /// non-terminal `MollieCheckoutEvent`. Returns `nil` for the two
        /// terminal `ChannelEvent` cases — those are surfaced exclusively
        /// via `mapFinalEvent(cardResult:)` off the coordinator's return
        /// value, so a checkout's stream never double-emits its terminal
        /// event once from a mid-flow tick and again from the final result.
        static func mapNonTerminalEvent(_ event: ChannelEvent) -> MollieCheckoutEvent? {
            switch event {
            case let .sessionUpdated(session):
                .processing(session)
            case let .threeDSChallengeReady(url):
                .challengePresented(url)
            case let .redirectRequired(url):
                .challengePresented(url)
            case .sessionCompleted, .sessionFailed:
                nil
            case .attemptFailed:
                // Mirrors the terminal cases above: `CardPaymentCoordinator`
                // never routes `.attemptFailed` through `onEvent` — it
                // returns it directly as the terminal `CardPaymentResult` of
                // `submit(_:)` (see `handleAttemptFailed`), which
                // `mapFinalEvent(cardResult:)` maps onto the real
                // `MollieCheckoutEvent.attemptFailed(retryable:error:)`. So
                // this mid-attempt tick never fires in practice; `nil` keeps
                // the switch exhaustive without fabricating a duplicate
                // event.
                nil
            }
        }

        /// Pick the real-time channels client for a session. When the session's
        /// `clientToken` advertises Pusher support AND carries a
        /// `pusherConfiguration` block, we wire the live `PusherChannelsClient`
        /// (the doorbell transport) using the credentials, channel, and event
        /// exactly as sent by the backend; otherwise we keep the inert
        /// `NoOpChannelsClient` so the engine stays poll-only. There is no
        /// hardcoded app key — a token with Pusher enabled but no configuration,
        /// or an incomplete one (any empty field), fails safe to polling rather
        /// than guessing connection parameters.
        static func makeChannelsClient(clientToken: ClientToken) -> any MollieChannelsClient {
            guard clientToken.isPusherEnabled else {
                MollieLogger.log("Pusher", "disabled — feature flag off; polling only")
                return NoOpChannelsClient()
            }
            guard let config = clientToken.pusherConfiguration else {
                MollieLogger.log("Pusher", "disabled — no pusherConfiguration in token; polling only")
                return NoOpChannelsClient()
            }
            guard !config.key.isEmpty, !config.cluster.isEmpty,
                  !config.channel.isEmpty, !config.event.isEmpty
            else {
                // Pusher off, no configuration, or a partially-empty block →
                // stay poll-only rather than opening a broken subscription.
                MollieLogger.log("Pusher", "disabled — incomplete pusherConfiguration (empty field); polling only")
                return NoOpChannelsClient()
            }
            MollieLogger.log(
                "Pusher",
                "enabled channel=\(config.channel) event=\(config.event) cluster=\(config.cluster)"
            )
            return PusherChannelsClient(
                credentials: PusherCredentials(appKey: config.key, cluster: config.cluster),
                channelName: config.channel,
                eventName: config.event
            )
        }

        /// Render `SessionResponse.status` (a `ParsedEnum<SessionStatus>`)
        /// as a flat string for the DevTools timeline. Mirrors the demo's
        /// `statusString` helper so the displayed value stays consistent
        /// across surfaces.
        ///
        /// `nonisolated` because `onSessionUpdate` is `@Sendable` and fires
        /// from whichever actor the channel/poller is running on; we don't
        /// want to force a hop onto the main actor just to format a string.
        nonisolated static func statusString(_ status: ParsedEnum<SessionStatus>) -> String {
            switch status {
            case let .known(value): value.rawValue
            case let .unknown(raw): raw
            }
        }
    }

    /// Sendable one-shot flag used to dedup the belt-and-braces
    /// `.sessionFetched` emit against the poller-driven one. Read/written
    /// from `@Sendable` closures on whichever queue the channel or poller is
    /// running on, so guarded by NSLock.
    final class SessionEmitFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var _fired = false

        var fired: Bool {
            lock.lock()
            defer { lock.unlock() }
            return _fired
        }

        func mark() {
            lock.lock()
            defer { lock.unlock() }
            _fired = true
        }
    }
#endif
