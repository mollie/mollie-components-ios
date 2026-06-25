#if canImport(UIKit)
    import Foundation
    @preconcurrency import MollieCore
    @preconcurrency import MolliePayments
    import MolliePaymentsUI
    import UIKit

    /// Internal orchestrator behind `MolliePaymentCardFormView` — the
    /// embeddable SwiftUI surface for the Mollie card form.
    ///
    /// Parallel to `PaymentSheetCoordinator` but without modal presentation:
    /// the form view-controller is owned by the host (SwiftUI's
    /// `UIViewControllerRepresentable`), so this type only wires the
    /// submit/cancel callbacks, runs the tokenise + 3DS + poll inner loop,
    /// and delivers a single terminal `MolliePaymentResult` through the
    /// `onResult` callback.
    ///
    /// Single-shot guard prevents double-delivery races between the natural
    /// terminal path (submit → result) and any externally-triggered cancel
    /// (host swipes away the screen before tokenise returns).
    @MainActor
    final class EmbeddedCardFormCoordinator {
        let clientToken: ClientToken
        let rawClientToken: String
        let theme: MolliePaymentTheme
        let endpoints: MolliePaymentEndpoints

        private var onResult: ((MolliePaymentResult) -> Void)?
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
            theme: MolliePaymentTheme,
            endpoints: MolliePaymentEndpoints,
            onResult: @escaping (MolliePaymentResult) -> Void
        ) {
            self.clientToken = clientToken
            self.rawClientToken = rawClientToken
            self.theme = theme
            self.endpoints = endpoints
            self.onResult = onResult
        }

        deinit {
            // Mirror of PaymentSheetCoordinator's submit-task cancellation
            // in `resolveAndDismiss`: if this coordinator is being torn down
            // before a terminal hit (e.g. SwiftUI replaced the embed view
            // identity), cancel any in-flight network call so it doesn't
            // race a freshly-instantiated coordinator's submit. Captured by
            // value to keep the deinit Sendable-clean.
            submitTask?.cancel()
        }

        func handleSubmit(snapshot: CardFormSnapshot) {
            switch PaymentSheetCoordinator.parse(snapshot: snapshot) {
            case let .failure(error):
                resolve(.failed(error))
            case let .success(submission):
                submitTask = Task { [weak self] in
                    guard let self else { return }
                    let result = await runSubmit(submission)
                    guard !Task.isCancelled else { return }
                    resolve(result)
                }
            }
        }

        func handleCancel() {
            resolve(.cancelled)
        }

        private func runSubmit(_ submission: CardSubmissionData) async -> MolliePaymentResult {
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
            let container = ViewControllerChallengeContainer(presentingViewController: presenter)
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
            return PaymentSheetCoordinator.map(cardResult: cardResult)
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
    }

    /// Mirror of `PaymentSheetCoordinator`'s fileprivate extension so the
    /// embed coordinator can emit the same outcome strings on the timeline.
    /// `internal` (file-scope by convention) keeps the symbol off the public
    /// surface but reachable from within the module.
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
