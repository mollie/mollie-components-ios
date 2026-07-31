#if canImport(UIKit) && canImport(WebKit)
    import MollieCore
    import UIKit

    /// UIKit-backed `ChallengeContainer` that pushes the 3-D Secure WebView
    /// onto a host `UINavigationController` and reports user-initiated pops
    /// (back button / interactive pop gesture) back to the coordinator so the
    /// awaiting continuation can resolve as `.cancelled`.
    /// Made public for demo target access; will be re-evaluated once the `MollieComponents` umbrella target ships.
    public final class UINavigationChallengeContainer: NSObject, @unchecked Sendable {
        let navigationController: UINavigationController
        /// Set by `ThreeDSCoordinator` while a challenge VC is on the stack.
        /// Fires exactly once on user-initiated pop; cleared by the coordinator
        /// when it pops the VC itself after a result.
        fileprivate var onPop: (@MainActor () -> Void)?
        /// The pushed challenge VC. Used to detect *its* removal vs other
        /// navigation activity happening on the same nav controller.
        fileprivate weak var challengeVC: UIViewController?
        /// Preserves any pre-existing delegate so we don't silently steal it.
        private weak var previousDelegate: UINavigationControllerDelegate?

        public init(navigationController: UINavigationController) {
            self.navigationController = navigationController
            super.init()
            previousDelegate = navigationController.delegate
            navigationController.delegate = self
        }

        deinit {
            // Best-effort restore on dealloc. Safe because UIKit serializes
            // delegate access on the main thread.
            if navigationController.delegate === self {
                navigationController.delegate = previousDelegate
            }
        }
    }

    extension UINavigationChallengeContainer: ChallengeContainer {}

    extension UINavigationChallengeContainer: UINavigationControllerDelegate {
        public func navigationController(
            _ navigationController: UINavigationController,
            didShow viewController: UIViewController,
            animated: Bool
        ) {
            // Forward to any prior delegate so we play nicely with hosts that
            // already had one configured.
            previousDelegate?.navigationController?(navigationController, didShow: viewController, animated: animated)

            // If our challenge VC is no longer on the stack, the user popped it
            // (back button / gesture); the coordinator's own pop path clears
            // `onPop` before popping so we don't double-resolve.
            guard let challenge = challengeVC,
                  !navigationController.viewControllers.contains(challenge)
            else { return }
            let pop = onPop
            onPop = nil
            challengeVC = nil
            pop?()
        }
    }

    final class ThreeDSCoordinator: ChallengePresenting, @unchecked Sendable {
        // Associated-object key used to retain `ModalDismissDelegate` for the
        // lifetime of a presented navigation controller (UIKit retains
        // presentation controller delegates weakly).
        // swiftlint:disable:next modifier_order
        fileprivate nonisolated(unsafe) static var dismissDelegateKey: UInt8 = 0

        /// In-flight watchdog Task for the modal presentation path. Cancelled
        /// from `ContinuationResolver.resolve(emitting:)` so the 5-minute sleep
        /// is torn down promptly on early resolution rather than holding the
        /// coordinator (and its captured `nav`) alive for the full timeout.
        private var watchdogTask: Task<Void, Never>?

        /// Set while a presentation is in flight; torn down by `dismiss()`.
        ///
        /// `CardPaymentCoordinator.drainEvents` races this
        /// presenter against continued poll-stream draining, because a
        /// frictionless hosted 3DS page completes the payment server-side
        /// without ever navigating to the return URL or firing the
        /// `mollie-interceptor` postMessage — leaving `present`/
        /// `presentRedirect` stranded even after the poller has already
        /// observed `.sessionCompleted`/`.sessionFailed`. When the poll side
        /// wins, the coordinator calls `dismiss()` (see `ChallengePresenting`)
        /// to tear down the modal/pushed WebView and resolve the pending
        /// continuation as `.cancelled` instead of leaving it stranded until
        /// the 5-minute watchdog.
        private var activeDismiss: (@MainActor () -> Void)?

        /// Resolved UI locale threaded from `CardPaymentCoordinator`, in
        /// turn from `MollieCheckout`/`MollieCardComponent`'s resolved
        /// locale. Threaded into `ThreeDSWebViewController`, whose
        /// `threeds.title`/`status.authenticating`/`cancel` copy is resolved
        /// from this locale via `MolliePaymentsBundleLocator.localizedBundle(for:)`.
        private let locale: Locale

        init(locale: Locale = .current) {
            self.locale = locale
        }

        func dismiss() async {
            await MainActor.run { [weak self] in
                self?.activeDismiss?()
                self?.activeDismiss = nil
            }
        }

        func present(challengeURL: URL, in container: any ChallengeContainer) async -> ThreeDSResult {
            await presentOnMain(challengeURL: challengeURL, merchantReturnURL: nil, in: container)
        }

        func present(
            challengeURL: URL,
            returnURL: URL?,
            in container: any ChallengeContainer
        ) async -> ThreeDSResult {
            // Wires the merchant's `redirectUrl` from the session into the
            // WebView's navigation policy so an ACS bouncing back to the
            // merchant host dismisses the modal instead of stranding the
            // user on the merchant-return page. Routes through the same
            // `presentOnMain` body the redirect-actionType path already
            // uses; the only difference is the call-site (challenge path
            // vs redirect path).
            await presentOnMain(challengeURL: challengeURL, merchantReturnURL: returnURL, in: container)
        }

        func presentRedirect(url: URL, returnURL: URL?, in container: any ChallengeContainer) async -> ThreeDSResult {
            // The hosted redirect page (pay.mollie.nl/payment/prepare-authentication)
            // runs no `mollie-interceptor` and emits no `challenge` postMessage,
            // so it cannot be revealed event-driven. Use the eager short-delay
            // present: the hosted page emits no `challenge`, so there is nothing to
            // gate on. We host it off-screen and only present it if it hasn't
            // resolved (navigated back to the merchant return URL) within the
            // watchdog window — giving a frictionless redirect the chance to finish
            // invisibly, while a genuinely interactive hosted page surfaces after
            // the delay. Empirically tunable.
            await presentOnMain(
                challengeURL: url,
                merchantReturnURL: returnURL,
                revealPolicy: .eager(delay: 10),
                in: container
            )
        }

        // swiftlint:disable opening_brace cyclomatic_complexity
        @MainActor
        private func presentOnMain(challengeURL: URL, merchantReturnURL: URL?,
                                   revealPolicy: ThreeDSWebViewController.RevealPolicy = .challengeDriven(watchdog: 15),
                                   in container: any ChallengeContainer) async -> ThreeDSResult
        {
            // swiftlint:enable opening_brace cyclomatic_complexity
            // Modal path — preferred for sheet-based UI. Presents the
            // 3DS WebView modally from a host VC; swipe-to-dismiss resolves
            // `.cancelled` via `ModalDismissDelegate`. A 5-minute watchdog
            // guards against ACS pages that never call back.
            if let vcContainer = container as? ViewControllerChallengeContainer {
                return await withCheckedContinuation { (continuation: CheckedContinuation<ThreeDSResult, Never>) in
                    // Resolver cancels the watchdog on the winning resolution path,
                    // so the 5-minute sleep doesn't retain anything after completion.
                    let resolver = ContinuationResolver(continuation: continuation) { [weak self] in
                        Task { @MainActor in
                            self?.watchdogTask?.cancel()
                            self?.watchdogTask = nil
                            self?.activeDismiss = nil
                        }
                    }
                    // Present-on-demand: load the WebView OFF-SCREEN so its 3DS
                    // round-trip runs invisibly while the merchant's own UI stays
                    // on screen. We present a modal ONLY when the controller asks
                    // (a `challenge` event, or its watchdog) — a frictionless flow
                    // resolves first and is torn down without ever presenting, so
                    // the user sees no intermediary screen.
                    let webVC = ThreeDSWebViewController(
                        challengeURL: challengeURL,
                        merchantReturnURL: merchantReturnURL,
                        revealPolicy: revealPolicy,
                        presentOnDemand: true,
                        locale: locale
                    )

                    // Shared main-actor reference to the modal once (if) presented.
                    var presentedNav: UINavigationController?

                    // `vcContainer` is captured STRONGLY: presentation is deferred
                    // (watchdog / challenge event), so the container must outlive
                    // the synchronous setup or `present()` would silently no-op and
                    // the flow would hang on the merchant spinner. Released when the
                    // watchdog (which strongly holds `webVC`) is torn down on resolve.
                    let present: @MainActor () -> Void = { [weak webVC] in
                        guard let webVC, presentedNav == nil else { return }
                        // Re-parent the already-loaded view out of the window; UIKit
                        // moves it into the nav on present (no reload).
                        webVC.view.removeFromSuperview()
                        webVC.view.isUserInteractionEnabled = true
                        let nav = UINavigationController(rootViewController: webVC)
                        nav.modalPresentationStyle = .fullScreen
                        let dismissDelegate = ModalDismissDelegate { resolver.resolve(emitting: .cancelled) }
                        nav.presentationController?.delegate = dismissDelegate
                        // UIKit only weakly retains presentation-controller delegates.
                        objc_setAssociatedObject(
                            nav,
                            &Self.dismissDelegateKey,
                            dismissDelegate,
                            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
                        )
                        presentedNav = nav
                        vcContainer.presentingViewController.present(nav, animated: true)
                    }
                    webVC.onNeedsPresentation = present

                    // Wired for `dismiss()` (poll-race): tears down
                    // whatever is currently showing (presented modal, or the
                    // hidden off-screen host) and resolves `.cancelled`.
                    activeDismiss = { [weak webVC] in
                        if let nav = presentedNav {
                            nav.presentingViewController?.dismiss(animated: true)
                        } else {
                            webVC?.view.removeFromSuperview()
                        }
                        resolver.resolve(emitting: .cancelled)
                    }

                    webVC.onResult = { [weak webVC] result in
                        resolver.resolve(emitting: result)
                        if let nav = presentedNav {
                            // Tear the modal down so the merchant doesn't see a
                            // stranded sheet after a terminal result.
                            nav.presentingViewController?.dismiss(animated: true)
                        } else {
                            // Never presented (frictionless) — drop the hidden host.
                            webVC?.view.removeFromSuperview()
                        }
                    }

                    // Host the controller's view behind the merchant UI in the
                    // on-screen window — occluded but in a live window so WebKit keeps
                    // the page's JS running (`isUserInteractionEnabled=false` so it
                    // can't steal a touch). With no window to hide behind, surface
                    // immediately rather than run the flow invisibly.
                    webVC.view.isUserInteractionEnabled = false
                    if let hostWindow = vcContainer.presentingViewController.viewIfLoaded?.window {
                        webVC.view.frame = hostWindow.bounds
                        webVC.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                        hostWindow.insertSubview(webVC.view, at: 0)
                    } else {
                        webVC.loadViewIfNeeded()
                        present()
                    }

                    // 5-minute watchdog. ACS pages that hang indefinitely would
                    // otherwise strand the awaiting continuation. Tears down
                    // whatever is showing (or the hidden host). Holds `webVC`
                    // STRONGLY so the off-screen controller (and, through its
                    // `onNeedsPresentation`, the container) survives until the flow
                    // resolves — the watchdog is cancelled on resolve, releasing it.
                    watchdogTask = Task { [webVC] in
                        try? await Task.sleep(nanoseconds: 5 * 60 * 1_000_000_000)
                        if Task.isCancelled {
                            return
                        }
                        if !resolver.hasResolved {
                            await MainActor.run {
                                if let nav = presentedNav {
                                    nav.presentingViewController?.dismiss(animated: true)
                                } else {
                                    webVC.view.removeFromSuperview()
                                }
                                resolver.resolve(emitting: .failed(reason: .sdkError(message: "timeout")))
                            }
                        }
                    }
                }
            }

            guard let uiContainer = container as? UINavigationChallengeContainer else {
                // The opaque protocol exists so non-UIKit tests can mock the
                // boundary. The real path requires one of the UIKit-backed
                // containers (modal `ViewControllerChallengeContainer` or
                // push-based `UINavigationChallengeContainer`).
                return .failed(
                    reason: .sdkError(
                        message: "ChallengeContainer must be UINavigationChallengeContainer or ViewControllerChallengeContainer"
                    )
                )
            }
            return await withCheckedContinuation { (continuation: CheckedContinuation<ThreeDSResult, Never>) in
                let webVC = ThreeDSWebViewController(
                    challengeURL: challengeURL,
                    revealPolicy: revealPolicy,
                    locale: locale
                )
                let resolver = ContinuationResolver(continuation: continuation) { [weak self] in
                    Task { @MainActor in
                        self?.activeDismiss = nil
                    }
                }

                uiContainer.challengeVC = webVC
                uiContainer.onPop = { [weak uiContainer] in
                    uiContainer?.challengeVC = nil
                    resolver.resolve(emitting: .cancelled)
                }

                // Wired for `dismiss()` (poll-race): pops the pushed
                // challenge VC (if still on top) and resolves `.cancelled`.
                activeDismiss = { [weak uiContainer, weak webVC] in
                    guard let uiContainer, let webVC else {
                        resolver.resolve(emitting: .cancelled)
                        return
                    }
                    uiContainer.onPop = nil
                    uiContainer.challengeVC = nil
                    if uiContainer.navigationController.topViewController === webVC {
                        uiContainer.navigationController.popViewController(animated: true)
                    }
                    resolver.resolve(emitting: .cancelled)
                }

                webVC.onResult = { [weak uiContainer] result in
                    guard let uiContainer else {
                        resolver.resolve(emitting: result)
                        return
                    }
                    // We're popping ourselves — clear the pop observer so
                    // `didShow` doesn't double-resolve as `.cancelled`.
                    uiContainer.onPop = nil
                    uiContainer.challengeVC = nil
                    if uiContainer.navigationController.topViewController === webVC {
                        uiContainer.navigationController.popViewController(animated: true)
                    }
                    resolver.resolve(emitting: result)
                }

                uiContainer.navigationController.pushViewController(webVC, animated: true)
            }
        }
    }

    /// Single-shot continuation guard. UIKit races (e.g. `didShow` after a
    /// manual pop on the same runloop tick) can fire two resolution paths;
    /// resuming a continuation twice traps in Swift's runtime.
    private final class ContinuationResolver: @unchecked Sendable {
        private let continuation: CheckedContinuation<ThreeDSResult, Never>
        private var resolved = false
        private let lock = NSLock()
        /// Hook run on the winning resolution path (used to cancel the modal
        /// watchdog Task so its 5-minute sleep doesn't outlive completion).
        private let onResolved: (@Sendable () -> Void)?

        init(
            continuation: CheckedContinuation<ThreeDSResult, Never>,
            onResolved: (@Sendable () -> Void)? = nil
        ) {
            self.continuation = continuation
            self.onResolved = onResolved
        }

        /// Thread-safe peek used by the modal-path timeout watchdog to
        /// decide whether to fire its timeout resolution.
        var hasResolved: Bool {
            lock.lock()
            defer { lock.unlock() }
            return resolved
        }

        func resolve(_ result: ThreeDSResult) {
            lock.lock()
            let shouldResolve = !resolved
            resolved = true
            lock.unlock()
            guard shouldResolve else { return }
            onResolved?()
            continuation.resume(returning: result)
        }

        /// Resolve while also emitting a DevTools lifecycle event derived
        /// from `result`. Emit happens only on the first (winning) call —
        /// late resolution attempts stay silent so DevTools sees one event
        /// per challenge attempt, matching the single-shot continuation.
        ///
        /// Reason tokens are stable (never `String(describing:)`) so DevTools
        /// rules and tests can pattern-match without depending on Swift's
        /// enum reflection format. Known tokens: `"challengeFailed"`,
        /// `"timeout"`, `"cancelled"`, plus any `sdkError` message which is
        /// already a curated stable string from the producing site.
        func resolve(emitting result: ThreeDSResult) {
            lock.lock()
            let shouldResolve = !resolved
            resolved = true
            lock.unlock()
            guard shouldResolve else { return }
            onResolved?()
            continuation.resume(returning: result)
        }
    }

    /// Bridges `UIAdaptivePresentationControllerDelegate.presentationControllerDidDismiss`
    /// (which fires on swipe-to-dismiss) into the resolver as `.cancelled`.
    private final class ModalDismissDelegate: NSObject, UIAdaptivePresentationControllerDelegate {
        private let onDismiss: () -> Void
        init(onDismiss: @escaping () -> Void) {
            self.onDismiss = onDismiss
        }

        func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
            onDismiss()
        }
    }
#endif
