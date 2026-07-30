#if canImport(UIKit)
    import Combine
    import Foundation
    @preconcurrency import MollieCore
    @preconcurrency import MolliePayments
    import MolliePaymentsUI
    import UIKit

    /// Single owner of a checkout's session context — the client token
    /// (both raw and decoded) plus the endpoints it talks to — vended once
    /// and reused to present the card form either as a UIKit modal or a
    /// SwiftUI component. The host owns presentation in both cases: this
    /// type never presents a sheet on its own — `presentCard(from:)`
    /// presents modally from a host-supplied `UIViewController`, and
    /// `makeCardComponent(onResult:)` vends an embeddable `View` the
    /// host places inside its own layout (including its own `.sheet`, if it
    /// wants a modal presentation).
    ///
    /// There is no public way to override the sheet's appearance — every
    /// entry point always renders with the Mollie-branded default theme.
    ///
    /// Construction decodes the client token eagerly (via
    /// `CardCheckoutRunner.decode`) so a malformed token fails fast at
    /// `MollieCheckout` build time rather than surfacing later when a
    /// component is presented.
    ///
    /// Both vending paths share the tokenise/submit/3DS logic in
    /// `CardCheckoutRunner.submit(...)` — this type owns the session context
    /// both paths need plus the presentation shell each one requires
    /// (`CardCheckoutModalCoordinator` for the modal, `EmbeddedFormBridge`
    /// inside `MollieCardComponent` for the embed).
    public struct MollieCheckout: Sendable {
        private let rawClientToken: String
        /// Decoded once at construction time — the source of truth for
        /// session context, handed to `CardCheckoutModalCoordinator` as-is so
        /// `presentCard` never re-decodes a token it already validated.
        private let decodedClientToken: ClientToken
        public let endpoints: MollieEndpoints
        /// Reserved for future localization — stored but not
        /// yet wired to any user-facing string in the sheet. Defaults to
        /// `.current` so merchants who pass it get the behaviour they'd
        /// expect once localization ships, without needing a follow-up
        /// migration.
        public let locale: Locale
        /// Backing store for `events`/`eventsPublisher` — a reference type so
        /// every copy of this `Sendable` value struct, and every attempt run
        /// through it, broadcasts into the same underlying stream. See
        /// `CheckoutEventBridge`'s doc comment for the "session stays open
        /// across attempts" semantics this encodes.
        private let eventBridge = CheckoutEventBridge()
        /// Awaited once per submit attempt, after tokenization and before
        /// the checkout-attempt request goes out — lets the merchant inject
        /// `MollieCustomerDetails` or veto the submission. Forwarded
        /// verbatim to `CardPaymentCoordinator.beforeSubmit`; see its doc
        /// comment for the throw-handling contract.
        private let beforeSubmit: (@Sendable () async throws -> MollieCustomerDetails?)?

        /// - Throws: `MollieError.invalidClientToken` if `clientToken` isn't
        ///   a valid base64-encoded client token payload.
        public init(
            clientToken: String,
            locale: Locale = .current,
            beforeSubmit: (@Sendable () async throws -> MollieCustomerDetails?)? = nil
        ) throws {
            switch CardCheckoutRunner.decode(clientToken: clientToken) {
            case let .success(decoded):
                decodedClientToken = decoded
            case let .failure(error):
                throw error
            }
            rawClientToken = clientToken
            endpoints = .production
            self.locale = locale
            self.beforeSubmit = beforeSubmit
        }

        /// Session-shaped, observable outcome of this checkout as an
        /// `AsyncStream`. A fresh stream is vended on every access; each
        /// tap receives the same events. The stream finishes once a
        /// terminal `MollieCheckoutEvent` (`.completed`/`.failed`) fires —
        /// non-terminal events, including `.cancelled`, leave it open for a
        /// further attempt.
        public var events: AsyncStream<MollieCheckoutEvent> {
            eventBridge.makeStream()
        }

        /// Combine counterpart of `events`, for callers already using
        /// Combine pipelines. Completes on the same terminal event.
        public var eventsPublisher: AnyPublisher<MollieCheckoutEvent, Never> {
            eventBridge.publisher
        }

        /// Present the Mollie card-payment form modally from the given UIKit
        /// host. The host owns presentation — this just drives the modal's
        /// navigation stack, the tokenise/submit/3DS loop, and the awaited
        /// terminal result on top of it — and feeds `events`/`eventsPublisher`
        /// alongside the returned terminal result. Always
        /// renders with the Mollie-branded default theme — there is no
        /// public way to override appearance.
        @MainActor
        public func presentCard(
            from host: UIViewController
        ) async -> MolliePaymentResult {
            let coordinator = CardCheckoutModalCoordinator(
                clientToken: decodedClientToken,
                rawClientToken: rawClientToken,
                theme: .default,
                endpoints: endpoints,
                checkoutEventSink: { [eventBridge] event in eventBridge.emit(event) },
                beforeSubmit: beforeSubmit
            )
            let result = await coordinator.present(from: host)
            // Single choke point for the terminal event: `result` is what
            // every exit path of `CardCheckoutModalCoordinator.present` —
            // network outcome, invalid snapshot, cancel, unattached-host
            // guard — already funnels into, so pushing here (once, after the
            // call returns) covers all of them without double-emitting
            // non-terminal `.cancelled` from inside the coordinator.
            eventBridge.emit(CardCheckoutRunner.mapEvent(from: result))
            return result
        }

        #if canImport(SwiftUI)
            /// Vend the embeddable SwiftUI card form for this checkout's
            /// session context. Mirrors
            /// `MollieCardComponent.init(clientToken:onResult:)`
            /// and, like `presentCard(from:)`, feeds
            /// `events`/`eventsPublisher` alongside `onResult`. Always
            /// renders with the Mollie-branded default theme — there is no
            /// public way to override appearance.
            public func makeCardComponent(
                onFieldEvent: ((MollieCardFieldEvent) -> Void)? = nil,
                onResult: @escaping (MolliePaymentResult) -> Void
            ) -> MollieCardComponent {
                MollieCardComponent(
                    clientToken: rawClientToken,
                    theme: .default,
                    endpoints: endpoints,
                    checkoutEventSink: { [eventBridge] event in eventBridge.emit(event) },
                    beforeSubmit: beforeSubmit,
                    onFieldEvent: onFieldEvent,
                    onResult: { [eventBridge] result in
                        // Same single-choke-point reasoning as
                        // `presentCard(from:)`: `result` is what every
                        // exit path of `MollieCardComponent`'s embed bridge
                        // already funnels into, via this wrapped `onResult`.
                        eventBridge.emit(CardCheckoutRunner.mapEvent(from: result))
                        onResult(result)
                    }
                )
            }
        #endif
    }

    /// Internal orchestrator behind `MollieCheckout.presentCard(from:)`.
    ///
    /// Owns the navigation stack that hosts the card form and any 3-D Secure
    /// challenge, owns the awaited continuation, and resolves it on exactly
    /// one terminal signal: successful payment, failure, or user-initiated
    /// cancellation (cancel button, back gesture out of the 3DS challenge).
    /// The actual tokenise/submit/3DS work is delegated to
    /// `CardCheckoutRunner.submit(...)` — this type only owns the modal shell
    /// around it.
    ///
    /// Single-shot continuation guard prevents double-resume races between
    /// the coordinator returning and the host dismissing the modal on the
    /// same runloop tick.
    @MainActor
    final class CardCheckoutModalCoordinator: NSObject {
        private let clientToken: ClientToken
        private let rawClientToken: String
        private let theme: MollieAppearance
        private let endpoints: MollieEndpoints
        /// Optional sink fed the non-terminal `ChannelEvent` ticks observed
        /// mid-attempt (`.processing`/`.challengePresented`). The terminal
        /// event for this attempt is NOT pushed here — see
        /// `MollieCheckout.presentCard(from:)`'s doc comment for why.
        private let checkoutEventSink: (@Sendable (MollieCheckoutEvent) -> Void)?
        /// Merchant-supplied hook forwarded verbatim to
        /// `CardPaymentCoordinator`. See its `beforeSubmit` doc comment for
        /// the await point and throw-handling contract.
        private let beforeSubmit: (@Sendable () async throws -> MollieCustomerDetails?)?
        private var resolver: Resolver?
        private weak var navigationController: UINavigationController?
        /// Tracks the in-flight tokenise/submit Task spawned by `handleSubmit`
        /// so a cancellation (parent view pop, SwiftUI task cancellation,
        /// host dismisses the modal after submit) can tear down the network
        /// call instead of letting it run to completion behind a dismissed
        /// modal.
        private var submitTask: Task<Void, Never>?

        init(
            clientToken: ClientToken,
            rawClientToken: String,
            theme: MollieAppearance,
            endpoints: MollieEndpoints,
            checkoutEventSink: (@Sendable (MollieCheckoutEvent) -> Void)? = nil,
            beforeSubmit: (@Sendable () async throws -> MollieCustomerDetails?)? = nil
        ) {
            self.clientToken = clientToken
            self.rawClientToken = rawClientToken
            self.theme = theme
            self.endpoints = endpoints
            self.checkoutEventSink = checkoutEventSink
            self.beforeSubmit = beforeSubmit
        }

        func present(from host: UIViewController) async -> MolliePaymentResult {
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
                    // `presentCard(from:)`. The cancellation hits
                    // `withTaskCancellationHandler` below and immediately
                    // resolves the modal with `.cancelled` — the host sees
                    // the form blink open and close. `.overFullScreen` keeps
                    // the presenter alive in the hierarchy with identical
                    // visual chrome.
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
            switch CardCheckoutRunner.parse(snapshot: snapshot) {
            case let .failure(error):
                resolveAndDismiss(.failed(error))
            case let .success(submission):
                // Hold the in-flight Task so `resolveAndDismiss` can cancel
                // it before the modal tears down. Without this, a host-
                // triggered dismiss or external SwiftUI cancellation
                // mid-tokenise leaks the network request through to
                // completion behind a dismissed UI.
                submitTask = Task { [weak self] in
                    guard let self else { return }
                    let result = await runSubmit(submission)
                    // If the Task was cancelled (modal already torn down),
                    // skip the resolve — the cancellation path already
                    // delivered `.cancelled` to the merchant.
                    guard !Task.isCancelled else { return }
                    resolveAndDismiss(result)
                }
            }
        }

        private func runSubmit(_ submission: CardSubmissionData) async -> MolliePaymentResult {
            guard let nav = navigationController else {
                return .failed(.invalidConfiguration(field: "modal", reason: "navigation controller deallocated"))
            }
            return await CardCheckoutRunner.submit(
                submission,
                clientToken: clientToken,
                rawClientToken: rawClientToken,
                endpoints: endpoints,
                presentingViewController: nav,
                checkoutEventSink: checkoutEventSink,
                beforeSubmit: beforeSubmit
            )
        }

        private func handleCancel() {
            resolveAndDismiss(.cancelled)
        }

        /// Resolve the awaited continuation exactly once, then dismiss the
        /// modal. Subsequent calls are ignored — guards against the form
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
    }

    extension CardCheckoutModalCoordinator: UIAdaptivePresentationControllerDelegate {
        nonisolated func presentationControllerDidDismiss(_: UIPresentationController) {
            // Host-triggered swipe-to-dismiss on the modal. The presented
            // view is already gone by the time this fires;
            // `resolveAndDismiss`'s `dismiss(animated:)` call on an
            // already-dismissed VC is a documented no-op, so it's safe to
            // route through the shared teardown path (which also cancels the
            // in-flight submit Task).
            Task { @MainActor [weak self] in
                self?.resolveAndDismiss(.cancelled)
            }
        }
    }

    /// Single-shot continuation guard. Mirrors `ContinuationResolver` from
    /// `ThreeDSCoordinator`. Without it, a submit-then-dismiss
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
