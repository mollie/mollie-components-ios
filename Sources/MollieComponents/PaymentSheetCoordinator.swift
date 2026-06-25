#if canImport(UIKit)
    import Foundation
    @preconcurrency import MollieCore
    @preconcurrency import MolliePayments
    import MolliePaymentsUI
    import UIKit

    /// Internal orchestrator behind `MolliePaymentSheet.present(...)`.
    ///
    /// Owns the navigation stack that hosts the card form and any 3-D Secure
    /// challenge, owns the `CardPaymentCoordinator`, owns the awaited
    /// continuation, and resolves it on exactly one terminal signal:
    /// successful payment, failure, or user-initiated cancellation (swipe to
    /// dismiss, cancel button, back gesture out of the 3DS challenge).
    ///
    /// Single-shot continuation guard prevents double-resume races between
    /// the coordinator returning and the user dismissing the sheet on the
    /// same runloop tick.
    @MainActor
    final class PaymentSheetCoordinator: NSObject {
        /// Entry point. Decodes the `clientToken`, presents the sheet from
        /// `host`, and awaits a single terminal `MolliePaymentResult`.
        static func run(
            from host: UIViewController,
            clientToken: String,
            theme: MolliePaymentTheme,
            endpoints: MolliePaymentEndpoints = .production
        ) async -> MolliePaymentResult {
            let decoded: ClientToken
            switch decode(clientToken: clientToken) {
            case let .success(token): decoded = token
            case let .failure(error): return .failed(error)
            }

            let coordinator = PaymentSheetCoordinator(
                clientToken: decoded,
                rawClientToken: clientToken,
                theme: theme,
                endpoints: endpoints
            )
            return await coordinator.present(from: host)
        }

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

        private let clientToken: ClientToken
        private let rawClientToken: String
        private let theme: MolliePaymentTheme
        private let endpoints: MolliePaymentEndpoints
        private var resolver: Resolver?
        private weak var navigationController: UINavigationController?
        /// Tracks the in-flight tokenise/submit Task spawned by `handleSubmit`
        /// so a cancellation (parent view pop, SwiftUI task cancellation,
        /// swipe-to-dismiss after submit) can tear down the network call
        /// instead of letting it run to completion behind a dismissed sheet.
        private var submitTask: Task<Void, Never>?

        private init(
            clientToken: ClientToken,
            rawClientToken: String,
            theme: MolliePaymentTheme,
            endpoints: MolliePaymentEndpoints
        ) {
            self.clientToken = clientToken
            self.rawClientToken = rawClientToken
            self.theme = theme
            self.endpoints = endpoints
        }

        private func present(from host: UIViewController) async -> MolliePaymentResult {
            // Guard against presenting on a detached host (host not attached
            // to a window — common in background launches / app extensions)
            // or stacking on top of an already-presented controller. Either
            // case would leave the continuation suspended forever; resolve
            // synchronously with a typed failure instead.
            guard host.view.window != nil else {
                return .failed(.invalidConfiguration(
                    field: "host",
                    reason: "host view controller is not attached to a window"
                ))
            }
            guard host.presentedViewController == nil else {
                return .failed(.invalidConfiguration(
                    field: "host",
                    reason: "host is already presenting another view controller"
                ))
            }

            // `withTaskCancellationHandler` is the SwiftUI-cancellation
            // safety net: if the caller's Task is cancelled while we're
            // suspended on the continuation (e.g. parent view pops and
            // SwiftUI tears down the `.task`), the `onCancel` closure hops
            // back to the main actor, resolves with `.cancelled`, and
            // dismisses the modal so it doesn't strand on screen. `Resolver`
            // is single-shot so any later natural terminal signal is a no-op.
            return await withTaskCancellationHandler {
                await withCheckedContinuation { (continuation: CheckedContinuation<MolliePaymentResult, Never>) in
                    resolver = Resolver(continuation: continuation)

                    let form = MollieCardFormViewController(theme: theme)
                    form.onSubmit = { [weak self] snapshot in
                        self?.handleSubmit(snapshot: snapshot)
                    }
                    form.onCancel = { [weak self] in
                        self?.handleCancel()
                    }

                    let nav = UINavigationController(rootViewController: form)
                    // `.overFullScreen` — full-screen takeover (no swipe-to-
                    // dismiss; user must hit the explicit Cancel button in
                    // `MollieCardFormViewController.handleCancel`).
                    //
                    // Deliberately NOT `.fullScreen`: that style removes the
                    // presenting view controller from the window hierarchy
                    // after the present animation, which propagates upward as
                    // SwiftUI cancelling the `.task` that drives
                    // `MolliePaymentSheet.present(...)`. The cancellation hits
                    // `withTaskCancellationHandler` below and immediately
                    // resolves the modal with `.cancelled` — the user sees the
                    // form blink open and close. `.overFullScreen` keeps the
                    // presenter alive in the hierarchy with identical visual
                    // chrome.
                    //
                    // `presentationControllerDidDismiss` is not vended by
                    // either `.fullScreen` or `.overFullScreen`; the delegate
                    // wire-up stays so a future revert to `.formSheet` /
                    // `.pageSheet` still works.
                    nav.modalPresentationStyle = .overFullScreen
                    nav.presentationController?.delegate = self
                    navigationController = nav

                    host.present(nav, animated: true)
                }
            } onCancel: {
                // `onCancel` is `@Sendable` and runs on whichever thread
                // triggered the cancellation. Hop back to the main actor to
                // touch the resolver / dismiss the modal. Capture `self`
                // weakly so a late cancellation after self has been released
                // is a no-op.
                Task { @MainActor [weak self] in
                    self?.resolveAndDismiss(.cancelled)
                }
            }
        }

        private func handleSubmit(snapshot: CardFormSnapshot) {
            switch Self.parse(snapshot: snapshot) {
            case let .failure(error):
                resolveAndDismiss(.failed(error))
            case let .success(submission):
                // Hold the in-flight Task so `resolveAndDismiss` can cancel
                // it before the sheet tears down. Without this, a swipe-to-
                // dismiss or external SwiftUI cancellation mid-tokenise
                // leaks the network request through to completion behind a
                // dismissed UI.
                submitTask = Task { [weak self] in
                    guard let self else { return }
                    let result = await runSubmit(submission)
                    // If the Task was cancelled (sheet already torn down),
                    // skip the resolve — the cancellation path already
                    // delivered `.cancelled` to the merchant.
                    guard !Task.isCancelled else { return }
                    resolveAndDismiss(result)
                }
            }
        }

        private func runSubmit(_ submission: CardSubmissionData) async -> MolliePaymentResult {
            guard let nav = navigationController else {
                return .failed(.invalidConfiguration(field: "sheet", reason: "navigation controller deallocated"))
            }
            let container = ViewControllerChallengeContainer(presentingViewController: nav)
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
                channelsClient: NoOpChannelsClient(),
                sessionToken: sessionToken,
                profileToken: clientToken.profileToken,
                testmode: clientToken.testmode,
                challengeContainer: container,
                onSessionUpdate: { session in
                    _ = session
                }
            )
            let cardResult = await coordinator.submit(submission)
            return Self.map(cardResult: cardResult)
        }

        /// Render `SessionResponse.status` (a `ParsedEnum<SessionStatus>`)
        /// as a flat string for the DevTools timeline. Mirrors the demo's
        /// `statusString` helper so the displayed value stays consistent
        /// across surfaces.
        ///
        /// `nonisolated` because `onSessionUpdate` is `@Sendable` and fires
        /// from whichever actor the channel/poller is running on; we don't
        /// want to force a hop onto the main actor just to format a string.
        ///
        /// `internal` (not `private`) so `@testable` tests can pin down the
        /// regression target: the original code hardcoded "open" and would
        /// emit the wrong value if the real status drifted. The test
        /// verifies that both known and unknown statuses round-trip back to
        /// their raw string form.
        nonisolated static func statusString(_ status: ParsedEnum<SessionStatus>) -> String {
            switch status {
            case let .known(value): value.rawValue
            case let .unknown(raw): raw
            }
        }

        private func handleCancel() {
            resolveAndDismiss(.cancelled)
        }

        /// Resolve the awaited continuation exactly once, then dismiss the
        /// sheet. Subsequent calls are ignored — guards against the form
        /// emitting a submit-then-cancel sequence on the same runloop, and
        /// against the SwiftUI cancellation handler racing the natural
        /// terminal path.
        ///
        /// Cancels the in-flight submit Task first so an in-flight tokenise/
        /// session-finalise request is torn down before the modal goes away,
        /// instead of completing against a dismissed UI.
        private func resolveAndDismiss(_ result: MolliePaymentResult) {
            guard let active = resolver else { return }
            resolver = nil
            submitTask?.cancel()
            submitTask = nil
            navigationController?.presentingViewController?.dismiss(animated: true)
            active.resolve(result)
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

        /// Map the engine's `CardPaymentResult` onto the merchant-facing
        /// `MolliePaymentResult`. The completed `SessionResponse` carries
        /// `sessionToken` and `paymentAmount` — that's the minimum the
        /// merchant needs to reconcile against their backend. Richer fields
        /// (payment id, method, metadata) become available once the
        /// Sessions Service surfaces them on the completed event.
        static func map(cardResult: CardPaymentResult) -> MolliePaymentResult {
            switch cardResult {
            case let .completed(session):
                let payment = MolliePayment(
                    sessionToken: session.sessionToken,
                    amount: session.paymentAmount.value,
                    currency: session.paymentAmount.currency
                )
                return .completed(payment)
            case let .failed(error):
                return .failed(error)
            case .cancelled:
                return .cancelled
            }
        }
    }

    extension PaymentSheetCoordinator: UIAdaptivePresentationControllerDelegate {
        nonisolated func presentationControllerDidDismiss(_: UIPresentationController) {
            // Swipe-to-dismiss on the modal sheet. The presented view is
            // already gone by the time this fires; `resolveAndDismiss`'s
            // `dismiss(animated:)` call on an already-dismissed VC is a
            // documented no-op, so it's safe to route through the shared
            // teardown path (which also cancels the in-flight submit Task).
            Task { @MainActor [weak self] in
                self?.resolveAndDismiss(.cancelled)
            }
        }
    }

    /// Single-shot continuation guard. Mirrors `ContinuationResolver` from
    /// `ThreeDSCoordinator` (Phase 2 / MR2). Without it, a submit-then-dismiss
    /// race or a coordinator-then-dismiss race resumes the continuation
    /// twice and traps in Swift's runtime.
    ///
    /// Internal (not private) so the idempotency invariant can be exercised
    /// directly from `@testable` unit tests without driving a real UIKit
    /// presentation. Still file-scoped by convention — no production code
    /// outside this file references it.
    final class Resolver: @unchecked Sendable {
        private let continuation: CheckedContinuation<MolliePaymentResult, Never>
        private var resolved = false
        private let lock = NSLock()

        init(continuation: CheckedContinuation<MolliePaymentResult, Never>) {
            self.continuation = continuation
        }

        func resolve(_ result: MolliePaymentResult) {
            lock.lock()
            let shouldResolve = !resolved
            resolved = true
            lock.unlock()
            guard shouldResolve else { return }
            continuation.resume(returning: result)
        }
    }

    /// Sendable one-shot flag used by `runSubmit` to dedup the
    /// belt-and-braces `.sessionFetched` emit against the poller-driven one.
    /// Read/written from `@Sendable` closures on whichever queue the channel
    /// or poller is running on, so guarded by NSLock.
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

    /// String form of the terminal outcome surfaced on the DevTools timeline.
    /// Kept fileprivate — this is purely an emit-site concern.
    fileprivate extension MolliePaymentResult {
        var outcomeString: String {
            switch self {
            case .completed: "completed"
            case .failed: "failed"
            case .cancelled: "cancelled"
            }
        }
    }
#endif
