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
        private var resolved = false
        private var webView: WKWebView?
        private var messageHandler: ThreeDSMessageHandler?

        init(challengeURL: URL, merchantReturnURL: URL? = nil) {
            self.challengeURL = challengeURL
            self.merchantReturnURL = merchantReturnURL
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
            // Pushed onto the host's nav stack — UIKit renders the system back
            // button automatically, and the coordinator observes the resulting
            // pop to surface `.cancelled`. No explicit Cancel item required.
            title = "3-D Secure"
        }

        private func resolve(_ result: ThreeDSResult) {
            guard !resolved else { return }
            resolved = true
            onResult?(result)
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
