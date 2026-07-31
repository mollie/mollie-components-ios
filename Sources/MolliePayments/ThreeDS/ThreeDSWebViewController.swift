#if canImport(UIKit) && canImport(WebKit)
    import MollieCore
    import UIKit
    import WebKit

    @MainActor
    final class ThreeDSWebViewController: UIViewController, WKNavigationDelegate {
        /// Instance-scoped renderer process pool. Each challenge attempt gets a
        /// fresh pool — no renderer-state (script caches, in-memory cookies the
        /// process pool may keep) carries across consecutive challenges. This
        /// makes back-to-back attempts behave as if they were in disjoint apps.
        private let processPool = WKProcessPool()

        var onResult: (@MainActor (ThreeDSResult) -> Void)?
        private let challengeURL: URL
        private let returnURLMatcher = ThreeDSReturnURLMatcher()
        private let hostedCheckoutCancelMatcher = MollieHostedCheckoutCancelMatcher()
        /// When set, main-frame navigation to this URL is treated as the
        /// dismissal signal for the `redirect`-flow (Mollie hosted page →
        /// merchant redirectUrl). Distinct from `returnURLMatcher` which only
        /// catches the ACS-back-to-Mollie pattern. Scheme drives matching:
        /// custom scheme → prefix match + `UIApplication.open` handoff;
        /// http/https → host equality, in-WebView render.
        private let merchantReturnURL: URL?
        /// Strategy for lifting the "Authenticating…" cover.
        ///
        /// - `challengeDriven`: the interceptor `challenge_url` path. The cover
        ///   stays up while the `mollie-interceptor` runs the 3DS method
        ///   invisibly; it is lifted the instant a genuine `challenge`
        ///   escalation arrives (see `receive(_:)`). `watchdog` is only a long
        ///   safety backstop so a silent / broken interceptor can't hide the
        ///   page forever — it is NOT a heuristic reveal timer.
        /// - `eager`: the hosted `redirect` path (pay.mollie.nl), which runs no
        ///   interceptor and emits no events. The cover is lifted after a short
        ///   `delay` so a frictionless-via-poll redirect is still suppressed
        ///   while a genuine interactive hosted page shows promptly.
        enum RevealPolicy: Equatable {
            case challengeDriven(watchdog: TimeInterval)
            case eager(delay: TimeInterval)

            var revealInterval: TimeInterval {
                switch self {
                case let .challengeDriven(watchdog): watchdog
                case let .eager(delay): delay
                }
            }
        }

        /// Drives the time-based arm of the reveal (see `RevealPolicy`).
        /// Injectable for tests.
        private let revealPolicy: RevealPolicy
        /// Present-on-demand mode. When true, the controller is hosted OFF-SCREEN
        /// by the coordinator (no cover, nothing presented): the WKWebView runs
        /// its 3DS round-trip invisibly while the merchant's own UI stays on
        /// screen. The controller asks to be presented — via `onNeedsPresentation`
        /// — only when an interactive challenge is genuinely required (a
        /// `challenge` event, or the watchdog firing). A frictionless flow
        /// resolves first and is torn down without ever presenting, so the user
        /// sees no intermediary screen. When false (legacy / pushed path) the
        /// controller installs the "Authenticating…" cover and reveals it in
        /// place, as before.
        private let presentOnDemand: Bool
        /// Fired (once) in present-on-demand mode when the controller needs to be
        /// surfaced to the user. The coordinator moves the hosted view into a
        /// modal and presents it.
        var onNeedsPresentation: (@MainActor () -> Void)?
        private var resolved = false
        private var revealed = false
        private var presentationRequested = false
        private var webView: WKWebView?
        private var coverView: UIView?
        private var revealTask: Task<Void, Never>?
        private var messageHandler: ThreeDSMessageHandler?

        /// Resolved UI locale, threaded from `ThreeDSCoordinator`.
        private let locale: Locale
        /// Locale-specific `.lproj` sub-bundle resolved once at init from
        /// `locale`, via `MolliePaymentsBundleLocator.localizedBundle(for:)`.
        /// Threaded into every localized-string call site in this controller
        /// (title, "Authenticating…" cover, Cancel button) instead of relying
        /// on `NSLocalizedString`'s default system-preferred-language
        /// selection — see the MolliePaymentsUI card-form counterpart for the
        /// full rationale.
        private let localizedBundle: Bundle

        init(
            challengeURL: URL,
            merchantReturnURL: URL? = nil,
            revealPolicy: RevealPolicy = .challengeDriven(watchdog: 15),
            presentOnDemand: Bool = false,
            locale: Locale = .current
        ) {
            self.challengeURL = challengeURL
            self.merchantReturnURL = merchantReturnURL
            self.revealPolicy = revealPolicy
            self.presentOnDemand = presentOnDemand
            self.locale = locale
            localizedBundle = MolliePaymentsBundleLocator.localizedBundle(for: locale)
            super.init(nibName: nil, bundle: nil)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("Not supported")
        }

        deinit {
            // WKUserContentController retains script message handlers strongly and
            // retains every added user script for the lifetime of the configuration.
            // Explicit removal on dealloc prevents the handler (and the injected
            // bridge JS) from outliving the controller through the WKWebView's
            // config graph — critical when the controller is recreated per
            // challenge attempt.
            let ucc = webView?.configuration.userContentController
            ucc?.removeScriptMessageHandler(forName: "mollieChallenge")
            ucc?.removeAllUserScripts()
        }

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .systemBackground
            let config = WKWebViewConfiguration()
            // Always use a non-persistent data store scoped to the challenge
            // lifetime. No cross-challenge cookie continuity — every challenge
            // starts with a clean cookie jar. (Prior attempts at iOS 17+
            // persistent data stores carried a hardcoded UUID and risked
            // cross-merchant cookie sharing.)
            config.websiteDataStore = .nonPersistent()
            // Share a single 3DS-only process pool — isolates renderer state
            // from the host app's own WebViews without leaking cookies/storage.
            config.processPool = processPool

            // Inject a postMessage bridge so the ACS page's `window.postMessage`
            // callbacks reach the native handler. Runs at document start in
            // the main frame only so it's installed before any ACS script.
            //
            // Origin filter: exact-match allow-list, no wildcards. Hosts come
            // from Swift, not the JS literal, so:
            //   - A compromised marketing/CMS page on `*.mollie.com` cannot
            //     forge an authenticated postMessage (the wildcard subdomain
            //     match this used to do is GONE).
            //   - Any new Mollie host that needs to postMessage must be added
            //     EXPLICITLY to `threeDSPostMessageAllowedHosts(challengeURL:)`.
            let allowedHostsJSON = threeDSPostMessageAllowedHostsJSON(challengeURL: challengeURL)
            let bridgeJS = makeThreeDSBridgeJS(allowedHostsJSON: allowedHostsJSON)
            let userScript = WKUserScript(
                source: bridgeJS,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
            config.userContentController.addUserScript(userScript)

            let handler = ThreeDSMessageHandler { [weak self] event in self?.receive(event) }
            messageHandler = handler
            config.userContentController.add(handler, name: "mollieChallenge")
            let webView = WKWebView(frame: view.bounds, configuration: config)
            webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            webView.navigationDelegate = self
            view.addSubview(webView)
            webView.load(URLRequest(url: challengeURL))
            self.webView = webView
            webView.accessibilityElementsHidden = true
            title = MollieLocalizedString(
                "threeds.title",
                bundle: localizedBundle,
                comment: "Navigation-bar title of the 3-D Secure challenge screen."
            )

            if presentOnDemand {
                // Hosted off-screen by the coordinator: no cover, nothing visible.
                // The WebView runs the 3DS round-trip invisibly; we surface the
                // controller (via the watchdog or a `challenge` event) only if an
                // interactive challenge is actually required. A Cancel item is
                // installed so the user can back out once we DO present (the
                // fullScreen modal has no interactive swipe-dismiss).
                navigationItem.leftBarButtonItem = UIBarButtonItem(
                    barButtonSystemItem: .cancel,
                    target: self,
                    action: #selector(cancelTapped)
                )
            } else {
                // Legacy / pushed path: keep the WebView hidden behind a branded
                // "Authenticating…" cover and reveal it in place — on a genuine
                // `challenge` escalation, or the scheduled fallback timer.
                installAuthenticatingCover()
            }
            scheduleReveal()
        }

        private func resolve(_ result: ThreeDSResult) {
            guard !resolved else { return }
            resolved = true
            // The flow terminated (navigation match / cancel) before any reveal;
            // make sure the deferred reveal can never fire afterwards.
            revealTask?.cancel()
            revealTask = nil
            onResult?(result)
        }

        /// Routes a parsed interceptor bridge event from the postMessage handler.
        /// A `.challengeEscalation` is non-terminal: the issuer is presenting an
        /// interactive challenge, so the cover lifts — but the flow does NOT
        /// resolve (the `resolved` guard is untouched), so a later terminal
        /// result still lands. A `.result` is terminal and resolves the flow.
        /// Internal so unit tests can drive the routing without a live
        /// `WKScriptMessage` (which has no public initialiser).
        func receive(_ event: ThreeDSBridgeEvent) {
            switch event {
            case .challengeEscalation:
                surface()
            case let .result(result):
                resolve(result)
            }
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            // Covers the poll-driven dismissal path: the coordinator may tear the
            // sheet down (e.g. a frictionless attempt completing via polling)
            // without a navigation-level resolve. Cancel the reveal so the raw
            // WebView is never flashed on the way out.
            revealTask?.cancel()
            revealTask = nil
        }

        // MARK: - Authenticating cover (event-driven reveal + watchdog)

        /// Schedules the time-based arm of the reveal: the long safety watchdog
        /// on the interceptor path, or the short reveal delay on the eager
        /// redirect path (see `RevealPolicy`). On the interceptor path the cover
        /// is normally lifted earlier by a `challenge` escalation via
        /// `receive(_:)`; this task fires only if no such event ever arrives.
        private func scheduleReveal() {
            revealTask?.cancel()
            let delay = revealPolicy.revealInterval
            revealTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                if Task.isCancelled {
                    return
                }
                self?.surface()
            }
        }

        /// Make the challenge visible to the user. In present-on-demand mode this
        /// asks the coordinator to present the off-screen-hosted controller; in
        /// the legacy/pushed mode it lifts the in-place "Authenticating…" cover.
        /// A no-op once the flow has resolved.
        private func surface() {
            guard !resolved else { return }
            if presentOnDemand {
                requestPresentation()
            } else {
                revealWebView()
            }
        }

        /// Present-on-demand: surface the off-screen-hosted controller. Single-shot.
        private func requestPresentation() {
            guard !resolved, !presentationRequested else { return }
            presentationRequested = true
            webView?.accessibilityElementsHidden = false
            onNeedsPresentation?()
        }

        /// Legacy/pushed path: reveal the live WebView by removing the
        /// "Authenticating…" cover. Single-shot, and a no-op once the flow has
        /// resolved. Internal so unit tests can drive the reveal deterministically
        /// without racing the timer.
        func revealWebView() {
            guard !revealed, !resolved else { return }
            revealed = true
            webView?.accessibilityElementsHidden = false
            if let webView {
                UIAccessibility.post(notification: .screenChanged, argument: webView)
            }
            guard let cover = coverView else { return }
            coverView = nil
            UIView.animate(withDuration: 0.2, animations: {
                cover.alpha = 0
            }, completion: { _ in
                cover.removeFromSuperview()
            })
        }

        /// Test seam: whether the controller has asked to be presented
        /// (present-on-demand mode). Internal for unit tests.
        var hasRequestedPresentation: Bool {
            presentationRequested
        }

        @objc private func cancelTapped() {
            resolve(.cancelled)
        }

        private func installAuthenticatingCover() {
            let cover = UIView(frame: view.bounds)
            cover.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            cover.backgroundColor = .systemBackground

            let spinner = UIActivityIndicatorView(style: .large)
            spinner.translatesAutoresizingMaskIntoConstraints = false
            spinner.startAnimating()

            let label = UILabel()
            label.translatesAutoresizingMaskIntoConstraints = false
            label.text = MollieLocalizedString(
                "threeds.status.authenticating",
                bundle: localizedBundle,
                comment: "Status label shown on the cover while the 3-D Secure challenge loads."
            )
            label.textColor = .secondaryLabel
            label.font = .preferredFont(forTextStyle: .body)
            label.textAlignment = .center
            label.numberOfLines = 0

            let cancel = UIButton(type: .system)
            cancel.translatesAutoresizingMaskIntoConstraints = false
            cancel.setTitle(
                MollieLocalizedString(
                    "threeds.cancel",
                    bundle: localizedBundle,
                    comment: "Cancel button shown on the 3-D Secure 'Authenticating…' cover."
                ),
                for: .normal
            )
            cancel.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)

            cover.addSubview(spinner)
            cover.addSubview(label)
            cover.addSubview(cancel)
            view.addSubview(cover)
            coverView = cover

            NSLayoutConstraint.activate([
                spinner.centerXAnchor.constraint(equalTo: cover.centerXAnchor),
                spinner.centerYAnchor.constraint(equalTo: cover.centerYAnchor),
                label.topAnchor.constraint(equalTo: spinner.bottomAnchor, constant: 16),
                label.leadingAnchor.constraint(greaterThanOrEqualTo: cover.leadingAnchor, constant: 24),
                label.trailingAnchor.constraint(lessThanOrEqualTo: cover.trailingAnchor, constant: -24),
                label.centerXAnchor.constraint(equalTo: cover.centerXAnchor),
                cancel.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 24),
                cancel.centerXAnchor.constraint(equalTo: cover.centerXAnchor),
            ])
        }

        // MARK: - WKNavigationDelegate

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            let bypassUnsafe = false
            let decision = threeDSWebViewPolicy(
                for: navigationAction.request.url,
                isMainFrame: navigationAction.targetFrame?.isMainFrame ?? true,
                isResolved: resolved,
                bypassUnsafeNavigation: bypassUnsafe,
                returnMatcher: returnURLMatcher,
                cancelMatcher: hostedCheckoutCancelMatcher,
                merchantReturnURL: merchantReturnURL
            )
            decisionHandler(decision.policy)
            if let urlToOpen = decision.openExternalURL {
                // Async-dispatched so it runs after this delegate returns. The
                // open's completion handler is independent of `resolve` below —
                // the sheet must dismiss whether or not iOS accepts the open
                // (custom scheme may be unregistered on the host). Only the
                // success Bool is logged; the URL is merchant-controlled and
                // may carry order/customer context, so it never reaches the
                // debug sink.
                DispatchQueue.main.async {
                    UIApplication.shared.open(urlToOpen, options: [:])
                }
            }
            if let resolution = decision.resolution {
                resolve(resolution)
            }
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation?,
            withError error: Error
        ) {
            // Don't leak `error.localizedDescription` (may contain attacker-
            // controlled URLs / hostnames). Surface a stable reason token derived
            // from the NSError code.
            let nsError = error as NSError
            // -999 is NSURLErrorCancelled — happens when we cancel the redirect
            // ourselves via `decisionHandler(.cancel)` above. Don't double-resolve.
            if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled {
                return
            }
            resolve(.failed(reason: .sdkError(message: "navigation_error_\(nsError.code)")))
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation?, withError error: Error) {
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled {
                return
            }
            resolve(.failed(reason: .sdkError(message: "navigation_error_\(nsError.code)")))
        }
    }

#endif
