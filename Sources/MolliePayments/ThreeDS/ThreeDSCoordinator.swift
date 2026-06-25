#if canImport(UIKit) && canImport(WebKit)
    import MollieCore
    import UIKit

    /// UIKit-backed `ChallengeContainer` that pushes the 3-D Secure WebView
    /// onto a host `UINavigationController` and reports user-initiated pops
    /// (back button / interactive pop gesture) back to the coordinator so the
    /// awaiting continuation can resolve as `.cancelled`.
    /// Made public for demo target access; will be re-evaluated when MollieComponents umbrella ships in Phase 4.
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

        init() {}

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
            await presentOnMain(challengeURL: url, merchantReturnURL: returnURL, in: container)
        }

        // swiftlint:disable opening_brace
        @MainActor
        private func presentOnMain(challengeURL: URL, merchantReturnURL: URL?,
                                   in container: any ChallengeContainer) async -> ThreeDSResult
        {
            // swiftlint:enable opening_brace
            // Modal path — preferred for Phase 4 sheet-based UI. Presents the
            // 3DS WebView modally from a host VC; swipe-to-dismiss resolves
            // `.cancelled` via `ModalDismissDelegate`. A 5-minute watchdog
            // guards against ACS pages that never call back.
            if let vcContainer = container as? ViewControllerChallengeContainer {
                return await withCheckedContinuation { (continuation: CheckedContinuation<ThreeDSResult, Never>) in
                    // Resolver cancels the watchdog on the winning resolution path,
                    // so the 5-minute sleep doesn't retain `nav` after early completion.
                    let resolver = ContinuationResolver(continuation: continuation) { [weak self] in
                        // Hop to the main actor because the watchdog Task is
                        // also mutated from the main-actor-bound presentation
                        // path; doing both reads/writes on the same actor
                        // sidesteps the `@unchecked Sendable` storage race.
                        Task { @MainActor in
                            self?.watchdogTask?.cancel()
                            self?.watchdogTask = nil
                        }
                    }
                    let webVC = ThreeDSWebViewController(
                        challengeURL: challengeURL,
                        merchantReturnURL: merchantReturnURL
                    )

                    let dismissDelegate = ModalDismissDelegate { resolver.resolve(emitting: .cancelled) }

                    let nav = UINavigationController(rootViewController: webVC)
                    nav.modalPresentationStyle = .fullScreen
                    nav.presentationController?.delegate = dismissDelegate

                    webVC.onResult = { [weak nav] result in
                        resolver.resolve(emitting: result)
                        // Tear the modal down ourselves on a programmatic
                        // result so the merchant doesn't see a stranded
                        // sheet after `.authenticated` / `.failed`.
                        nav?.presentingViewController?.dismiss(animated: true)
                    }

                    // Keep the dismiss delegate alive for the lifetime of the
                    // presentation. UIKit only weakly retains presentation
                    // controller delegates.
                    objc_setAssociatedObject(
                        nav,
                        &Self.dismissDelegateKey,
                        dismissDelegate,
                        .OBJC_ASSOCIATION_RETAIN_NONATOMIC
                    )

                    vcContainer.presentingViewController.present(nav, animated: true)

                    // 5-minute watchdog. ACS pages that hang indefinitely
                    // would otherwise strand the awaiting continuation.
                    // `[weak self, weak nav]` so the watchdog never extends
                    // coordinator or nav-controller lifetime; cancellation from
                    // the resolver tears it down on early completion.
                    watchdogTask = Task { [weak nav] in
                        try? await Task.sleep(nanoseconds: 5 * 60 * 1_000_000_000)
                        if Task.isCancelled { return }
                        if !resolver.hasResolved {
                            await MainActor.run {
                                nav?.presentingViewController?.dismiss(animated: true)
                                // Stable reason token (`"timeout"`) — DevTools / tests
                                // can match on it without parsing free-form messages.
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
                let webVC = ThreeDSWebViewController(challengeURL: challengeURL)
                let resolver = ContinuationResolver(continuation: continuation)

                uiContainer.challengeVC = webVC
                uiContainer.onPop = { [weak uiContainer] in
                    uiContainer?.challengeVC = nil
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
