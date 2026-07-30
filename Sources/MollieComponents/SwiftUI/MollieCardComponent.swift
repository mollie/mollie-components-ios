#if canImport(UIKit) && canImport(SwiftUI)
    import Foundation
    @preconcurrency import MollieCore
    @preconcurrency import MolliePayments
    import MolliePaymentsUI
    import SwiftUI
    import UIKit

    /// Embeddable SwiftUI surface for the Mollie card form.
    ///
    /// Drop this view directly into any host layout (a checkout screen, a
    /// settings page, anywhere) and the SDK card form renders inline. The
    /// form's own "Pay with card" button is the CTA — no modal sheet, no
    /// nav controller required. On any terminal state — `.completed`,
    /// `.failed`, `.cancelled` — `onResult` fires exactly once.
    ///
    /// For a modal presentation, wrap this view in the host's own `.sheet` —
    /// the SDK doesn't own presentation. Both `MollieCardComponent` and
    /// `MollieCheckout.presentCard(from:)` share the same
    /// `MolliePaymentResult` type — pick the one that fits the host's
    /// layout.
    ///
    /// There is no public way to override the sheet's appearance — this
    /// view always renders with the Mollie-branded default theme.
    public struct MollieCardComponent: View {
        private let clientToken: String
        private let theme: MollieAppearance
        private let endpoints: MollieEndpoints
        /// Non-nil only for the internal init used by
        /// `MollieCheckout.makeCardComponent(onResult:)`.
        private let checkoutEventSink: (@Sendable (MollieCheckoutEvent) -> Void)?
        /// Non-nil only for the internal init used by
        /// `MollieCheckout.makeCardComponent(onResult:)`.
        private let beforeSubmit: (@Sendable () async throws -> MollieCustomerDetails?)?
        private let onResult: (MolliePaymentResult) -> Void
        /// Fired on every per-keystroke edit and on blur for the field
        /// affected, reporting that field's live validity, error kind, and
        /// the currently-detected card scheme.
        private let onFieldEvent: ((MollieCardFieldEvent) -> Void)?

        public init(
            clientToken: String,
            onFieldEvent: ((MollieCardFieldEvent) -> Void)? = nil,
            onResult: @escaping (MolliePaymentResult) -> Void
        ) {
            self.clientToken = clientToken
            theme = .default
            // Always production for merchant code — a non-production
            // `MollieEndpoints` can't be constructed through the public
            // surface at all. Mirrors `MollieCheckout`'s init lockdown: no
            // `endpoints:` parameter on the public surface.
            endpoints = .production
            checkoutEventSink = nil
            beforeSubmit = nil
            self.onFieldEvent = onFieldEvent
            self.onResult = onResult
        }

        /// Internal-only entry point used exclusively by
        /// `MollieCheckout.makeCardComponent(onResult:)` to thread the
        /// checkout's observable event stream into the underlying
        /// coordinator. `checkoutEventSink` is required (not defaulted) here
        /// so this initializer can never be selected by accident in place of
        /// the public one — every call site must opt in explicitly.
        init(
            clientToken: String,
            theme: MollieAppearance = MollieAppearance(),
            endpoints: MollieEndpoints = .production,
            checkoutEventSink: @escaping @Sendable (MollieCheckoutEvent) -> Void,
            beforeSubmit: (@Sendable () async throws -> MollieCustomerDetails?)? = nil,
            onFieldEvent: ((MollieCardFieldEvent) -> Void)? = nil,
            onResult: @escaping (MolliePaymentResult) -> Void
        ) {
            self.clientToken = clientToken
            self.theme = theme
            self.endpoints = endpoints
            self.checkoutEventSink = checkoutEventSink
            self.beforeSubmit = beforeSubmit
            self.onFieldEvent = onFieldEvent
            self.onResult = onResult
        }

        public var body: some View {
            switch CardCheckoutRunner.decode(clientToken: clientToken) {
            case let .success(decoded):
                EmbeddedFormRepresentable(
                    decodedToken: decoded,
                    rawClientToken: clientToken,
                    theme: theme,
                    endpoints: endpoints,
                    checkoutEventSink: checkoutEventSink,
                    beforeSubmit: beforeSubmit,
                    onFieldEvent: onFieldEvent,
                    onResult: onResult
                )
            case let .failure(error):
                // Bail visibly: render nothing, deliver the typed failure
                // once on first appear, then leave the slot empty. The host
                // can react in `onResult` (e.g. dismiss the screen, surface
                // an error banner) without the SDK rendering any chrome.
                Color.clear
                    .frame(height: 0)
                    .task { onResult(.failed(error)) }
            }
        }
    }

    /// UIViewControllerRepresentable that mounts `MollieCardFormViewController`
    /// inside SwiftUI. Owns the coordinator instance so the form's submit/
    /// cancel callbacks drive the embed-side payment loop without a modal.
    private struct EmbeddedFormRepresentable: UIViewControllerRepresentable {
        let decodedToken: ClientToken
        let rawClientToken: String
        let theme: MollieAppearance
        let endpoints: MollieEndpoints
        let checkoutEventSink: (@Sendable (MollieCheckoutEvent) -> Void)?
        let beforeSubmit: (@Sendable () async throws -> MollieCustomerDetails?)?
        let onFieldEvent: ((MollieCardFieldEvent) -> Void)?
        let onResult: (MolliePaymentResult) -> Void

        @MainActor
        func makeCoordinator() -> EmbeddedFormBridge {
            EmbeddedFormBridge(
                clientToken: decodedToken,
                rawClientToken: rawClientToken,
                theme: theme,
                endpoints: endpoints,
                checkoutEventSink: checkoutEventSink,
                beforeSubmit: beforeSubmit,
                onResult: onResult
            )
        }

        func makeUIViewController(context: Context) -> MollieCardFormViewController {
            let form = MollieCardFormViewController(theme: theme)
            let coordinator = context.coordinator
            coordinator.formViewController = form
            form.onSubmit = { snapshot in
                MainActor.assumeIsolated {
                    coordinator.handleSubmit(snapshot: snapshot)
                }
            }
            form.onCancel = {
                MainActor.assumeIsolated {
                    coordinator.handleCancel()
                }
            }
            form.onFieldEvent = { internalEvent in
                onFieldEvent?(MollieCardFieldEvent(internalEvent))
            }
            return form
        }

        func updateUIViewController(_: MollieCardFormViewController, context _: Context) {
            // No-op. Form state lives inside the VC + the coordinator; we
            // never need to push fresh props down on a parent re-render
            // because `clientToken`/`theme`/etc. are captured into the
            // coordinator at `makeUIViewController` time and the embed
            // view's identity is keyed on `clientToken` upstream.
        }

        @MainActor
        func sizeThatFits(
            _ proposal: ProposedViewSize,
            uiViewController: MollieCardFormViewController,
            context _: Context
        ) -> CGSize? {
            // Ask the form's view what height it wants given the proposed
            // width. The form's outer stack uses a `lessThanOrEqual` bottom
            // anchor so this returns a true content-fit height — without
            // it the embed would stretch to fill whatever vertical slot
            // SwiftUI gave us.
            let targetWidth = proposal.width ?? UIView.layoutFittingExpandedSize.width
            let fitting = uiViewController.view.systemLayoutSizeFitting(
                CGSize(width: targetWidth, height: UIView.layoutFittingCompressedSize.height),
                withHorizontalFittingPriority: .required,
                verticalFittingPriority: .fittingSizeLevel
            )
            return CGSize(width: targetWidth, height: fitting.height)
        }
    }

    /// Internal orchestrator behind `MollieCardComponent`'s embed: owns the
    /// submit/cancel callbacks, runs the tokenise + 3DS + poll inner loop via
    /// `CardCheckoutRunner.submit(...)`, and delivers a single terminal
    /// `MolliePaymentResult` through the `onResult` callback.
    ///
    /// Single-shot guard prevents double-delivery races between the natural
    /// terminal path (submit → result) and any externally-triggered cancel
    /// (host swipes away the screen before tokenise returns).
    @MainActor
    final class EmbeddedFormBridge {
        let clientToken: ClientToken
        let rawClientToken: String
        let theme: MollieAppearance
        let endpoints: MollieEndpoints

        private var onResult: ((MolliePaymentResult) -> Void)?
        /// Optional sink fed the non-terminal `ChannelEvent` ticks observed
        /// mid-attempt (`.processing`/`.challengePresented`) — set only when
        /// driven through `MollieCheckout.makeCardComponent(onResult:)`;
        /// nil for the standalone
        /// `MollieCardComponent.init(clientToken:theme:endpoints:onResult:)`
        /// entry point. The terminal event is NOT pushed here — `MollieCheckout`
        /// derives it from the returned `MolliePaymentResult` instead.
        private let checkoutEventSink: (@Sendable (MollieCheckoutEvent) -> Void)?
        /// Merchant-supplied hook threaded from `MollieCheckout`/
        /// `MollieCardComponent`, forwarded verbatim to `CardPaymentCoordinator`.
        /// See `CardPaymentCoordinator.beforeSubmit`'s doc comment for the
        /// await point and throw-handling contract.
        private let beforeSubmit: (@Sendable () async throws -> MollieCustomerDetails?)?
        /// Tracks the in-flight tokenise/submit Task so a cancellation (host
        /// view torn down, screen popped) can tear down the network call
        /// instead of completing against a dismounted UI.
        private var submitTask: Task<Void, Never>?
        /// Weak handle so `cancelLoading()` can reset the button state if a
        /// late terminal arrives after the host has been popped.
        weak var formViewController: MollieCardFormViewController?

        init(
            clientToken: ClientToken,
            rawClientToken: String,
            theme: MollieAppearance,
            endpoints: MollieEndpoints,
            checkoutEventSink: (@Sendable (MollieCheckoutEvent) -> Void)? = nil,
            beforeSubmit: (@Sendable () async throws -> MollieCustomerDetails?)? = nil,
            onResult: @escaping (MolliePaymentResult) -> Void
        ) {
            self.clientToken = clientToken
            self.rawClientToken = rawClientToken
            self.theme = theme
            self.endpoints = endpoints
            self.checkoutEventSink = checkoutEventSink
            self.beforeSubmit = beforeSubmit
            self.onResult = onResult
        }

        deinit {
            // If this bridge is being torn down before a terminal hit (e.g.
            // SwiftUI replaced the embed view identity), cancel any in-flight
            // network call so it doesn't race a freshly-instantiated bridge's
            // submit. Captured by value to keep the deinit Sendable-clean.
            submitTask?.cancel()
        }

        func handleSubmit(snapshot: CardFormSnapshot) {
            switch CardCheckoutRunner.parse(snapshot: snapshot) {
            case let .failure(error):
                resolve(.failed(error))
            case let .success(submission):
                // `runSubmit` returns the
                // deprecated `MolliePaymentResult`, which can't distinguish a
                // retryable soft decline from a genuinely terminal failure
                // (see `CardCheckoutRunner.submit`'s doc comment). This flag
                // is marked from inside the wrapped `checkoutEventSink` the
                // moment `CardCheckoutRunner.submit` pushes the real
                // `.attemptFailed` event, so the branch below can tell them
                // apart without needing a richer return type.
                let attemptFailedFlag = SessionEmitFlag()
                submitTask = Task { [weak self] in
                    guard let self else { return }
                    let result = await runSubmit(submission, attemptFailedFlag: attemptFailedFlag)
                    guard !Task.isCancelled else { return }
                    if attemptFailedFlag.fired {
                        resetForRetry()
                    } else {
                        resolve(result)
                    }
                }
            }
        }

        func handleCancel() {
            resolve(.cancelled)
        }

        private func runSubmit(
            _ submission: CardSubmissionData,
            attemptFailedFlag: SessionEmitFlag
        ) async -> MolliePaymentResult {
            // The 3DS challenge presents modally on top of the host scene's
            // topmost VC — the embedded form stays mounted underneath. If the
            // app has no active scene (background, app extension), the
            // challenge would have nowhere to land; surface that as a typed
            // configuration failure instead of crashing later in
            // `ViewControllerChallengeContainer.present`.
            guard let presenter = SceneRootResolver.activeRootViewController() else {
                return .failed(.invalidConfiguration(
                    field: "scene",
                    reason: "no active scene to host 3DS challenge"
                ))
            }
            let sink = checkoutEventSink
            return await CardCheckoutRunner.submit(
                submission,
                clientToken: clientToken,
                rawClientToken: rawClientToken,
                endpoints: endpoints,
                presentingViewController: presenter,
                checkoutEventSink: { event in
                    if case .attemptFailed = event {
                        attemptFailedFlag.mark()
                    }
                    sink?(event)
                },
                beforeSubmit: beforeSubmit
            )
        }

        /// One-shot delivery. Subsequent calls (e.g. submit-then-cancel race)
        /// are no-ops. Also resets the form button's loading state so a
        /// merchant whose host sticks around after a failure / cancel sees
        /// the button rehydrate ready for a retry.
        private func resolve(_ result: MolliePaymentResult) {
            guard let callback = onResult else { return }
            onResult = nil
            submitTask?.cancel()
            submitTask = nil
            formViewController?.cancelLoading()
            callback(result)
        }

        /// A retryable soft decline ends this ONE
        /// submit attempt but not the session — the server already reset it
        /// to `CREATED` (see `CardPaymentResult.attemptFailed`'s doc
        /// comment). Unlike `resolve(_:)`, this does NOT clear `onResult` or
        /// invoke the merchant callback — there's no `MolliePaymentResult`
        /// case for a retryable decline — so the same bridge instance stays
        /// alive and accepts a fresh `handleSubmit`; only the form's loading
        /// state resets so the pay button is tappable again. Merchants
        /// watching `MollieCheckout.events`/`eventsPublisher` still see the
        /// real `.attemptFailed` event, pushed by `CardCheckoutRunner.submit`
        /// through `checkoutEventSink`.
        func resetForRetry() {
            submitTask = nil
            formViewController?.cancelLoading()
        }
    }

    /// Mirror of `CardCheckoutModalCoordinator`'s fileprivate extension so the
    /// embed bridge can emit the same outcome strings on the timeline.
    private extension MolliePaymentResult {
        var outcomeString: String {
            switch self {
            case .completed: "completed"
            case .failed: "failed"
            case .cancelled: "cancelled"
            }
        }
    }
#endif
