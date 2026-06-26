#if canImport(UIKit) && canImport(WebKit)
    import MollieCore
    import Network
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
        /// How long the WebView stays hidden behind the "Authenticating…" cover
        /// before being revealed. Frictionless / 3DS-method flows resolve (or the
        /// poll loop dismisses the sheet) before this elapses, so the raw WebView
        /// is never shown; a real interactive challenge outlives it and is
        /// revealed. Injectable for tests. See epic t330.
        private let revealDelay: TimeInterval
        private var resolved = false
        private var revealed = false
        private var webView: WKWebView?
        private var coverView: UIView?
        private var revealTask: Task<Void, Never>?
        private var messageHandler: ThreeDSMessageHandler?

        init(challengeURL: URL, merchantReturnURL: URL? = nil, revealDelay: TimeInterval = 3.0) {
            self.challengeURL = challengeURL
            self.merchantReturnURL = merchantReturnURL
            self.revealDelay = revealDelay
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

            let handler = ThreeDSMessageHandler { [weak self] result in self?.resolve(result) }
            messageHandler = handler
            config.userContentController.add(handler, name: "mollieChallenge")
            let webView = WKWebView(frame: view.bounds, configuration: config)
            webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            webView.navigationDelegate = self
            view.addSubview(webView)
            webView.load(URLRequest(url: challengeURL))
            self.webView = webView
            // Keep the WebView hidden behind a branded "Authenticating…" cover.
            // It is revealed only if a real interactive challenge outlives
            // `revealDelay`; frictionless / 3DS-method flows resolve (or the sheet
            // is dismissed by the poll loop) first, so the raw WebView never shows.
            webView.accessibilityElementsHidden = true
            installAuthenticatingCover()
            scheduleReveal()
            // Pushed onto the host's nav stack — UIKit renders the system back
            // button automatically, and the coordinator observes the resulting
            // pop to surface `.cancelled`. No explicit Cancel item required.
            title = "3-D Secure"
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

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            // Covers the poll-driven dismissal path: the coordinator may tear the
            // sheet down (e.g. a frictionless attempt completing via polling)
            // without a navigation-level resolve. Cancel the reveal so the raw
            // WebView is never flashed on the way out.
            revealTask?.cancel()
            revealTask = nil
        }

        // MARK: - Authenticating cover (deferred reveal)

        private func scheduleReveal() {
            revealTask?.cancel()
            let delay = revealDelay
            revealTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                if Task.isCancelled { return }
                self?.revealWebView()
            }
        }

        /// Reveal the live WebView by removing the "Authenticating…" cover.
        /// Single-shot, and a no-op once the flow has resolved. Internal so unit
        /// tests can drive the reveal deterministically without racing the timer.
        func revealWebView() {
            guard !revealed, !resolved else { return }
            revealed = true
            webView?.accessibilityElementsHidden = false
            if let webView { UIAccessibility.post(notification: .screenChanged, argument: webView) }
            guard let cover = coverView else { return }
            coverView = nil
            UIView.animate(withDuration: 0.2, animations: {
                cover.alpha = 0
            }, completion: { _ in
                cover.removeFromSuperview()
            })
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
            label.text = "Authenticating securely…"
            label.textColor = .secondaryLabel
            label.font = .preferredFont(forTextStyle: .body)
            label.textAlignment = .center
            label.numberOfLines = 0

            let cancel = UIButton(type: .system)
            cancel.translatesAutoresizingMaskIntoConstraints = false
            cancel.setTitle("Cancel", for: .normal)
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
            if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled { return }
            resolve(.failed(reason: .sdkError(message: "navigation_error_\(nsError.code)")))
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation?, withError error: Error) {
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled { return }
            resolve(.failed(reason: .sdkError(message: "navigation_error_\(nsError.code)")))
        }
    }

#endif
