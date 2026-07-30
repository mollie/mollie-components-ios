import Foundation
import MollieCore

/// Merges Pusher channel events with session-polling fallback into a single ChannelEvent stream.
/// Currently ships with a no-op channels client (Pusher integration deferred), so the consumer
/// falls back entirely to polling. The interface stays Pusher-shaped so a future swap to the
/// real PusherChannelsClient is configuration-only.
///
/// Two polling modes:
///  - Legacy (`observe(sessionToken:)`): polls `GET /sessions/{token}` via `SessionPoller.poll()`.
///  - Checkout-attempt (`observeAttempt()`): polls `GET /checkout-attempts/` via
///    `SessionPoller.pollAttempt()`. The `checkoutAttemptToken` is baked into the poller at
///    construction time; no second arg here so we cannot drift from the poller's view.
///
/// Wire→event mapping lives in `SessionEventMapper` (MollieCore) so the Pusher-
/// sourced re-fetch and this poll fallback map responses identically; the
/// consumer only adds the synthetic `.sessionUpdated` ordering in `yieldEvents`.
///
/// Note on V2 contract: the 3DS ACS URL arrives under `challengeUrl` (camelCase,
/// PayProc path) or `acsURL` (3DS-v2 path); the dev-harness/mock uses
/// `challenge_url`. `SessionEventMapper.threeDSChallengeURL(from:)` matches all
/// literal forms (reading only `challenge_url` dropped the real prod
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
                // Keep the Pusher subscription alive IN PARALLEL with polling.
                // Doorbells are not yet wired to a re-fetch on this legacy
                // session path (the checkout-attempt path does that on
                // `observeAttempt`), so they're
                // drained best-effort — but draining must never gate the poll
                // loop. A live `PusherChannelsClient`'s doorbell stream only
                // finishes on a fatal disconnect, so awaiting it *before*
                // polling (the previous behaviour) meant a healthy-but-quiet
                // socket blocked `poll()` from ever starting and the payment
                // hung with no independent timeout. Polling now starts
                // immediately; the poll loop owns termination and the overall
                // budget exactly as the poll-only path did. With
                // `NoOpChannelsClient` the doorbell task finishes at once, so
                // behaviour is identical to the pre-Pusher flow.
                let doorbellTask = Task {
                    if let stream = try? await channelsClient.subscribe(to: sessionToken) {
                        for await _ in stream {}
                    }
                }
                do {
                    for try await response in sessionPoller.poll() {
                        Self.yieldEvents(for: response, into: continuation)
                        if SessionEventMapper.isTerminal(SessionEventMapper.map(response: response)) {
                            break
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
                // Poll loop ended (terminal / budget / error / cancellation):
                // stop the parallel doorbell drain and release the socket.
                doorbellTask.cancel()
                await channelsClient.unsubscribe(from: sessionToken)
                await channelsClient.disconnect()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Default inactivity watchdog: if no doorbell arrives within this window,
    /// the consumer does one re-fetch and resets the timer. 15s mirrors the
    /// Web SDK's `SessionCheckoutAttemptService` safety net. Pusher is PRIMARY;
    /// the watchdog only covers the gap where the socket is alive but quiet
    /// (e.g. a missed/coalesced doorbell). It is NOT the overall poll budget —
    /// see the budget note in `observeAttempt`.
    package static let defaultWatchdogInterval: TimeInterval = 15

    /// Generous completion budget applied once an interactive 3DS challenge is
    /// in flight. A card 3DS attempt projection can stall at
    /// `AUTHENTICATION_PENDING` (no completion doorbell, projection not
    /// advanced) while the underlying SESSION reaches `completed`; the SDK must
    /// keep observing the session across the user's authentication rather than
    /// timing out on the shorter create-phase budget. 180s comfortably spans a
    /// hosted 3DS challenge; a completed/expired session resolves immediately.
    package static let defaultChallengeCompletionBudget: TimeInterval = 180

    /// Card-payment observation: the checkout-attempt path (`observeAttemptOnly`)
    /// merged with a CONCURRENT session-completion poll (`GET /sessions`).
    ///
    /// Why the concurrent session poll: for a card 3DS flow the backend's
    /// checkout-attempt projection can get stuck at `AUTHENTICATION_PENDING`
    /// (the `AUTHENTICATION_PENDING → COMPLETED` transition is invalid, so no
    /// attempt-level completion doorbell fires and the projection is not saved),
    /// while the SESSION resource reaches `completed`. Observing only the
    /// attempt path therefore times out on a paid+authorized payment. Polling
    /// the session concurrently and racing to the first terminal state closes
    /// that gap.
    ///
    /// Budget (challenge-aware): the attempt path keeps its base budget so a
    /// frictionless flow with no challenge still fails fast. Once a challenge/
    /// redirect is observed, the attempt-path timeout is swallowed and the
    /// session-completion poll (running with `challengeCompletionBudget`) becomes
    /// the authority — so an interactive challenge that takes longer than the
    /// base budget no longer aborts a successful payment. First terminal wins;
    /// the loser is cancelled.
    package func observeCardPayment( // swiftlint:disable:this cyclomatic_complexity
        sessionToken: String,
        watchdogInterval: TimeInterval = SessionEventConsumer.defaultWatchdogInterval,
        challengeCompletionBudget: TimeInterval = SessionEventConsumer.defaultChallengeCompletionBudget
    ) -> AsyncThrowingStream<ChannelEvent, Error> {
        // A non-positive budget disables the concurrent session poll and makes
        // this behave exactly as the attempt-only path — the seam tests use to
        // pin attempt-path behaviour without the session poll interfering.
        guard challengeCompletionBudget > 0 else {
            return observeAttempt(sessionToken: sessionToken, watchdogInterval: watchdogInterval)
        }
        let attemptStream = observeAttempt(sessionToken: sessionToken, watchdogInterval: watchdogInterval)
        let sessionPoller = sessionPoller
        let sessionSchedule = PollingSchedule(
            intervals: PollingSchedule.default.intervals,
            totalBudget: challengeCompletionBudget
        )
        return AsyncThrowingStream<ChannelEvent, Error> { continuation in
            let task = Task {
                enum Merge {
                    case attempt(ChannelEvent)
                    case attemptEnded
                    case attemptError(Error)
                    case sessionTerminal(ChannelEvent)
                    case sessionEnded
                    case sessionError(Error)
                }
                let (merged, mergedCont) = AsyncStream.makeStream(of: Merge.self)

                await withTaskGroup(of: Void.self) { group in
                    // Producer A — checkout-attempt path (challenge/redirect/
                    // updates + its own terminal + its own base budget).
                    group.addTask {
                        do {
                            for try await event in attemptStream {
                                mergedCont.yield(.attempt(event))
                            }
                            mergedCont.yield(.attemptEnded)
                        } catch {
                            mergedCont.yield(.attemptError(error))
                        }
                    }
                    // Producer B — concurrent session-completion poll.
                    group.addTask { [sessionPoller] in
                        do {
                            for try await response in sessionPoller.poll(schedule: sessionSchedule) {
                                let event = SessionEventMapper.map(response: response)
                                if SessionEventMapper.isTerminal(event) {
                                    mergedCont.yield(.sessionTerminal(event))
                                    return
                                }
                            }
                            mergedCont.yield(.sessionEnded)
                        } catch {
                            mergedCont.yield(.sessionError(error))
                        }
                    }

                    // Consumer — single-threaded decision loop; first terminal wins.
                    var challengeSeen = false
                    var attemptDone = false
                    var sessionDone = false
                    var pendingError: Error?
                    consume: for await signal in merged {
                        switch signal {
                        case let .attempt(event):
                            continuation.yield(event)
                            switch event {
                            case .threeDSChallengeReady, .redirectRequired:
                                challengeSeen = true
                            case .sessionCompleted, .sessionFailed:
                                continuation.finish()
                                break consume
                            default:
                                break
                            }
                        case let .sessionTerminal(event):
                            continuation.yield(event)
                            continuation.finish()
                            break consume
                        case let .attemptError(error):
                            attemptDone = true
                            if challengeSeen {
                                if sessionDone {
                                    continuation.finish(throwing: pendingError ?? error)
                                    break consume
                                }
                            } else {
                                continuation.finish(throwing: error)
                                break consume
                            }
                        case .attemptEnded:
                            attemptDone = true
                            if sessionDone {
                                continuation.finish(throwing: pendingError)
                                break consume
                            }
                        case .sessionEnded:
                            sessionDone = true
                            if attemptDone {
                                continuation.finish(throwing: pendingError)
                                break consume
                            }
                        case let .sessionError(error):
                            sessionDone = true
                            pendingError = error
                            if attemptDone {
                                continuation.finish(throwing: error)
                                break consume
                            }
                        }
                    }
                    group.cancelAll()
                    mergedCont.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Default production card-payment observation path.
    ///
    /// Concurrent merge (Pusher PRIMARY, polling as transparent fallback):
    ///  1. Subscribe to the `channelsClient` doorbell stream. Each
    ///     `ChannelDoorbell` triggers ONE `sessionPoller.fetchAttempt()`
    ///     (re-fetch `GET /checkout-attempts/`, look up this attempt). The
    ///     doorbell is a signal only — business state is read from the
    ///     re-fetched response, never from the doorbell payload.
    ///  2. Inactivity watchdog: if no doorbell arrives within
    ///     `watchdogInterval`, do one re-fetch. The timer resets on every
    ///     received doorbell AND every watchdog fetch.
    ///  3. Transparent fallback: when the doorbell stream finishes/fails
    ///     (Pusher fatal, or the NoOp client whose stream finishes
    ///     immediately), fail over to the existing timer-based
    ///     `pollAttempt()` loop. Failover is one-shot / one-directional
    ///     (Pusher → poll), matching the Web SDK.
    ///  4. Dedup by `nextAction.eventId` is owned HERE, across ALL fetch
    ///     sources (doorbell, watchdog, poll fallback), so overlapping
    ///     fetches never double-emit.
    ///
    /// Budget interplay: the overall `PollingSchedule` total budget (~30s
    /// default) bounds BOTH phases. The doorbell phase enforces it directly
    /// (raising `MollieError.timeout(operation: "checkout-attempt-doorbell")`
    /// if a quiet-but-connected socket never reaches terminal), and once we
    /// fall back to `pollAttempt()` that loop owns the same budget exactly as
    /// the legacy poll-only path did. The watchdog NEVER ends the stream — it
    /// only nudges an extra re-fetch while the doorbell phase is live; the
    /// overall deadline is the doorbell phase's terminator, so a healthy-but-
    /// quiet socket can no longer bypass the budget.
    ///
    /// NoOp parity: with `NoOpChannelsClient` the doorbell stream finishes
    /// immediately, so step 3 runs at once and behavior is IDENTICAL to the
    /// pre-Pusher poll-only flow (flag-off / non-Pusher sessions are unchanged).
    package func observeAttempt(
        sessionToken: String,
        watchdogInterval: TimeInterval = SessionEventConsumer.defaultWatchdogInterval
    ) -> AsyncThrowingStream<ChannelEvent, Error> {
        AsyncThrowingStream<ChannelEvent, Error> { continuation in
            let channelsClient = channelsClient
            let sessionPoller = sessionPoller
            let task = Task {
                // Single eventId dedup shared by doorbell, watchdog, and the
                // poll fallback. nil eventId is never deduped (the server
                // hasn't assigned an event yet) — mirrors pollAttempt().
                var lastEmittedEventId: Int?
                var hasEmitted = false

                /// Map a fetched response, applying dedup + yieldEvents
                /// ordering. Returns true when the response is terminal.
                ///
                /// Terminal status is AUTHORITATIVE over the eventId dedup:
                /// server invariant is that a status transition to a terminal
                /// state may or may not bump `nextAction.eventId`, so a terminal
                /// response that reuses the previous eventId (e.g. non-terminal
                /// eventId=5 then completed/expired eventId=5) must still be
                /// emitted and finish the stream — otherwise the duplicate
                /// short-circuit would drop it and the stream would resolve by
                /// timeout instead of terminal. We therefore compute terminality
                /// first and bypass the dedup for terminal responses.
                func process(_ response: SessionResponse) -> Bool {
                    let isTerminal = SessionEventMapper.isTerminal(SessionEventMapper.map(response: response))
                    let newEventId = response.nextAction.eventId
                    let isDuplicate = hasEmitted && newEventId != nil && newEventId == lastEmittedEventId
                    if isDuplicate, !isTerminal {
                        return false
                    }
                    hasEmitted = true
                    lastEmittedEventId = newEventId
                    Self.yieldEvents(for: response, into: continuation)
                    return isTerminal
                }

                // --- Pusher-primary doorbell + watchdog merge -------
                // Subscribe up front. A throwing/absent subscription falls
                // straight through to the poll fallback below. The phase
                // re-fetches per doorbell/watchdog tick and yields the per-
                // attempt responses back here; dedup + ordering stay in this
                // single task via `process`.
                if let doorbells = try? await channelsClient.subscribe(to: sessionToken) {
                    do {
                        var reachedTerminal = false
                        for try await response in Self.doorbellPhaseFetches(
                            doorbells: doorbells,
                            watchdogInterval: watchdogInterval,
                            totalBudget: sessionPoller.totalBudget,
                            fetch: { try await sessionPoller.fetchAttempt() }
                        ) {
                            reachedTerminal = process(response)
                            if reachedTerminal {
                                break
                            }
                        }
                        await channelsClient.unsubscribe(from: sessionToken)
                        await channelsClient.disconnect()
                        if reachedTerminal {
                            continuation.finish()
                            return
                        }
                        // Doorbell stream ended without a terminal state →
                        // Pusher fatal (or NoOp). Already torn down; fail over.
                    } catch {
                        // Cancellation or a non-transient fetch error during
                        // the doorbell phase. Tear down the subscription, then
                        // propagate (cancellation finishes silently).
                        await channelsClient.unsubscribe(from: sessionToken)
                        await channelsClient.disconnect()
                        if error is CancellationError {
                            continuation.finish()
                        } else {
                            continuation.finish(throwing: error)
                        }
                        return
                    }
                } else {
                    await channelsClient.unsubscribe(from: sessionToken)
                    await channelsClient.disconnect()
                }

                // --- Transparent poll fallback ----------------------
                // The existing timer-based loop owns the overall budget. Its
                // emissions still pass through `process` so the eventId dedup
                // spans the Pusher→poll handoff (a fetch right after failover
                // can repeat the last doorbell-emitted eventId).
                do {
                    for try await response in sessionPoller.pollAttempt() {
                        let reachedTerminal = process(response)
                        if reachedTerminal {
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

    /// Pusher-primary phase as a stream of re-fetched per-attempt responses.
    ///
    /// Internally races the doorbell stream against an inactivity watchdog: a
    /// doorbell pump child task and a watchdog child task both feed a single
    /// `triggers` stream; a third child task fetches once per trigger and yields
    /// each non-nil `SessionResponse` onto the returned stream. The consuming
    /// task (`observeAttempt`) owns dedup, ordering, and the terminal check, so
    /// the eventId dedup and the `yieldEvents` two-step ordering live in exactly
    /// one place — no business state crosses a concurrency boundary here.
    ///
    /// The returned stream finishes when the underlying doorbell stream ends
    /// (Pusher fatal / NoOp) — that's the signal for the caller to fail over to
    /// `pollAttempt()`. It finishes-throwing on a fetch error. On termination
    /// (caller cancels / breaks after terminal) the task group is cancelled and
    /// the watchdog stopped.
    ///
    /// The watchdog resets on EVERY trigger (doorbell or watchdog fetch) via
    /// `watchdog.poke()` before each fetch, so "no doorbell within
    /// `watchdogInterval`" is what makes it fire.
    ///
    /// Overall deadline: `totalBudget` bounds the whole phase. A deadline child
    /// task finishes-throwing `MollieError.timeout(operation:
    /// "checkout-attempt-doorbell")` once the budget elapses, so a quiet-but-
    /// connected socket (doorbell stream never ends, session never terminal)
    /// can't run unbounded — parity with the poll-only path's budget. A
    /// non-finite budget (`.infinity`) disables the deadline (the poll
    /// fallback's own caps still bound it), mirroring `runPollLoop`'s
    /// `totalBudget.isFinite` guard.
    ///
    /// Seeded initial fetch: a single trigger is yielded the moment the fetch
    /// loop starts, so the first `GET /checkout-attempts/` happens immediately
    /// after subscribe — not only once the first doorbell arrives or after
    /// `watchdogInterval`. This closes the pre-subscription doorbell race (the
    /// session-scoped doorbell can fire before the SDK is subscribed) and
    /// restores first-fetch parity with the poll-only leading poll. The
    /// caller's eventId dedup makes it idempotent against the first real
    /// doorbell, so there's no double-emit risk.
    private static func doorbellPhaseFetches(
        doorbells: AsyncStream<ChannelDoorbell>,
        watchdogInterval: TimeInterval,
        totalBudget: TimeInterval,
        fetch: @escaping () async throws -> SessionResponse?
    ) -> AsyncThrowingStream<SessionResponse, Error> {
        AsyncThrowingStream<SessionResponse, Error> { continuation in
            let driver = Task {
                // Merge doorbells + watchdog ticks into one trigger stream.
                let (triggers, triggerContinuation) = AsyncStream.makeStream(of: Void.self)
                let watchdog = WatchdogClock()

                await withTaskGroup(of: Void.self) { group in
                    // Overall deadline: bound the whole doorbell phase by
                    // `totalBudget`. On elapse, surface a timeout and cancel
                    // the group so the doorbell pump / watchdog / fetch loop all
                    // unwind. Skipped for a non-finite budget (`.infinity`),
                    // whose nanosecond conversion would overflow `UInt64`.
                    if totalBudget.isFinite {
                        group.addTask {
                            do {
                                try await Task.sleep(nanoseconds: UInt64(totalBudget * 1_000_000_000))
                            } catch {
                                return // cancelled (phase ended first) — no timeout
                            }
                            continuation.finish(
                                throwing: MollieError.timeout(operation: "checkout-attempt-doorbell")
                            )
                            await watchdog.stop()
                            triggerContinuation.finish()
                        }
                    }
                    // Doorbell pump: each doorbell is a trigger. When the
                    // underlying stream ends (Pusher fatal / NoOp), finish the
                    // trigger stream so the fetch loop drains and ends → caller
                    // fails over to polling.
                    group.addTask {
                        for await _ in doorbells {
                            triggerContinuation.yield(())
                        }
                        triggerContinuation.finish()
                    }
                    // Watchdog: fires a trigger after `watchdogInterval` of
                    // doorbell silence; each fired trigger is itself poked so
                    // the idle window restarts.
                    group.addTask {
                        while await watchdog.waitForIdle(seconds: watchdogInterval) {
                            triggerContinuation.yield(())
                        }
                    }
                    // Fetch loop: one fetch per trigger, yielded back to the
                    // caller. Resets the watchdog before each fetch. Seeds one
                    // trigger up front so the first fetch runs immediately after
                    // subscribe (closes the pre-subscription doorbell race).
                    group.addTask {
                        triggerContinuation.yield(())
                        do {
                            for await _ in triggers {
                                await watchdog.poke()
                                if let response = try await fetch() {
                                    continuation.yield(response)
                                }
                                // nil → transient miss: keep waiting for the
                                // next doorbell/watchdog tick.
                            }
                            continuation.finish()
                        } catch {
                            continuation.finish(throwing: error)
                        }
                        // Whatever ended the fetch loop ends the phase: stop the
                        // watchdog (its `waitForIdle` returns false → exits) and
                        // finish the trigger stream. The caller breaking the
                        // for-await fires `onTermination`, which cancels the
                        // driver task (and with it the doorbell pump + deadline).
                        await watchdog.stop()
                        triggerContinuation.finish()
                    }
                    await group.waitForAll()
                }
            }
            continuation.onTermination = { _ in driver.cancel() }
        }
    }

    /// Inactivity timer for the doorbell phase. `waitForIdle(seconds:)` returns
    /// `true` only when `seconds` elapse with no intervening `poke()` — i.e. the
    /// channel went quiet. Every `poke()` restarts the idle window (the
    /// "reset the watchdog on every received doorbell/fetch" requirement).
    /// `stop()` makes all current and future waits return `false` so the
    /// watchdog task exits cleanly on terminal/teardown.
    private actor WatchdogClock {
        private var generation = 0
        private var stopped = false

        func poke() {
            generation += 1
        }

        func stop() {
            stopped = true
            generation += 1
        }

        /// Returns true once `seconds` pass with no intervening `poke()`. A
        /// poke restarts the idle window internally (the watchdog keeps
        /// running). Returns false only when `stop()` was called or the sleep
        /// is cancelled, so the caller exits the watchdog loop for good.
        func waitForIdle(seconds: TimeInterval) async -> Bool {
            while !stopped {
                let mark = generation
                do {
                    try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                } catch {
                    return false // cancelled
                }
                if stopped {
                    return false
                }
                // Fired only if no poke moved the generation while we slept;
                // otherwise loop and restart the idle window.
                if generation == mark {
                    return true
                }
            }
            return false
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
        let mapped = SessionEventMapper.map(response: response)
        switch mapped {
        case .threeDSChallengeReady, .redirectRequired:
            continuation.yield(.sessionUpdated(response))
            continuation.yield(mapped)
        // .attemptFailed (retryable soft-decline) passes
        // through unchanged like the other non-URL cases; consumer-side
        // wiring (coordinator reset/retry UX) is scoped separately.
        case .sessionUpdated, .sessionCompleted, .sessionFailed, .attemptFailed:
            continuation.yield(mapped)
        }
    }
}
