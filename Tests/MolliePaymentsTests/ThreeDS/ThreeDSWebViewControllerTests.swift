#if canImport(WebKit)
    import WebKit
    import XCTest
    @testable import MolliePayments

    /// Unit tests for the pure policy + JS-bridge helpers extracted from
    /// `ThreeDSWebViewController`. Gated on WebKit only
    /// (not UIKit) so the assertions run on macOS as well as iOS — the
    /// controller class itself stays UIKit-only and its `deinit` test lives
    /// further down behind the stricter gate.
    final class ThreeDSWebViewPolicyTests: XCTestCase {
        // MARK: - threeDSWebViewPolicy(for:…) extracted helper

        private let returnMatcher = ThreeDSReturnURLMatcher()
        private let cancelMatcher = MollieHostedCheckoutCancelMatcher()

        func test_policy_javascriptScheme_cancelsAsUnsafe() throws {
            // `javascript:` is one of the schemes `isUnsafeNavigation` rejects
            // — adversarial input must cancel + emit a stable "Unsafe
            // navigation blocked" sdkError. This branch runs BEFORE any
            // matcher so a malicious ACS can't piggyback on a known return URL.
            let url = try XCTUnwrap(URL(string: "javascript:alert(1)"))
            let decision = threeDSWebViewPolicy(
                for: url,
                isMainFrame: true,
                isResolved: false,
                returnMatcher: returnMatcher,
                cancelMatcher: cancelMatcher,
                merchantReturnURL: nil
            )
            XCTAssertEqual(decision.policy, .cancel)
            XCTAssertEqual(
                decision.resolution,
                .failed(reason: .sdkError(message: "Unsafe navigation blocked"))
            )
        }

        func test_policy_httpScheme_cancelsAsUnsafe() throws {
            // Plaintext HTTP is a downgrade — block before any matcher runs.
            let url = try XCTUnwrap(URL(string: "http://secure-3ds.mollie.com/3ds/return?status=authenticated"))
            let decision = threeDSWebViewPolicy(
                for: url,
                isMainFrame: true,
                isResolved: false,
                returnMatcher: returnMatcher,
                cancelMatcher: cancelMatcher,
                merchantReturnURL: nil
            )
            XCTAssertEqual(decision.policy, .cancel)
            XCTAssertEqual(
                decision.resolution,
                .failed(reason: .sdkError(message: "Unsafe navigation blocked"))
            )
        }

        func test_policy_iframeNavToReturnURL_allowsWithoutResolving() throws {
            // Critical: an iframe navigating to the return URL must NOT
            // resolve. An ACS-controlled iframe pointing at
            // `?status=authenticated` would otherwise let an attacker skip
            // the challenge.
            let url = try XCTUnwrap(URL(string: "https://secure-3ds.mollie.com/3ds/return?status=authenticated"))
            let decision = threeDSWebViewPolicy(
                for: url,
                isMainFrame: false,
                isResolved: false,
                returnMatcher: returnMatcher,
                cancelMatcher: cancelMatcher,
                merchantReturnURL: nil
            )
            XCTAssertEqual(decision.policy, .allow)
            XCTAssertNil(decision.resolution)
        }

        func test_policy_mainFrameNavToReturnURLAuthenticated_cancelsAndResolves() throws {
            let url = try XCTUnwrap(URL(string: "https://secure-3ds.mollie.com/3ds/return?status=authenticated"))
            let decision = threeDSWebViewPolicy(
                for: url,
                isMainFrame: true,
                isResolved: false,
                returnMatcher: returnMatcher,
                cancelMatcher: cancelMatcher,
                merchantReturnURL: nil
            )
            XCTAssertEqual(decision.policy, .cancel)
            XCTAssertEqual(decision.resolution, .authenticated)
        }

        func test_policy_mainFrameNavToHostedCancel1008_cancelsAndResolvesCancelled() throws {
            // Verify the hosted-checkout-cancel guard chain end-to-end.
            let url = try XCTUnwrap(URL(string: "https://www.mollie.com/checkout/credit-card/return?error_code=1008"))
            let decision = threeDSWebViewPolicy(
                for: url,
                isMainFrame: true,
                isResolved: false,
                returnMatcher: returnMatcher,
                cancelMatcher: cancelMatcher,
                merchantReturnURL: nil
            )
            XCTAssertEqual(decision.policy, .cancel)
            XCTAssertEqual(decision.resolution, .cancelled)
        }

        func test_policy_mainFrameNavToHostedCancelEmptyErrorCode_allows() throws {
            // Empty `?error_code=` must NOT match the cancel matcher
            // — otherwise the WebView would dismiss with a useless
            // `mollie_error_` token. With the matcher returning false, the
            // policy helper must fall through to `.allow`.
            let url = try XCTUnwrap(URL(string: "https://www.mollie.com/checkout/credit-card/return?error_code="))
            let decision = threeDSWebViewPolicy(
                for: url,
                isMainFrame: true,
                isResolved: false,
                returnMatcher: returnMatcher,
                cancelMatcher: cancelMatcher,
                merchantReturnURL: nil
            )
            XCTAssertEqual(decision.policy, .allow)
            XCTAssertNil(decision.resolution)
        }

        func test_policy_mainFrameNavToMerchantReturnHost_cancelsAndResolvesAuthenticated() throws {
            // `redirect` actionType flow: merchant return host arrives in the
            // top frame → "presentation finished," poller resumes.
            let url = try XCTUnwrap(URL(string: "https://merchant.example.com/done"))
            let decision = threeDSWebViewPolicy(
                for: url,
                isMainFrame: true,
                isResolved: false,
                returnMatcher: returnMatcher,
                cancelMatcher: cancelMatcher,
                merchantReturnURL: URL(string: "https://merchant.example.com/return")
            )
            XCTAssertEqual(decision.policy, .cancel)
            XCTAssertEqual(decision.resolution, .authenticated)
        }

        func test_policy_alreadyResolved_alwaysAllows() throws {
            // After resolution, pending in-flight navs continue (WebKit settles
            // them) but never re-resolve. This is essentially a stronger form
            // of the `resolve()` guard, surfaced to the policy layer.
            let url = try XCTUnwrap(URL(string: "https://secure-3ds.mollie.com/3ds/return?status=authenticated"))
            let decision = threeDSWebViewPolicy(
                for: url,
                isMainFrame: true,
                isResolved: true,
                returnMatcher: returnMatcher,
                cancelMatcher: cancelMatcher,
                merchantReturnURL: nil
            )
            XCTAssertEqual(decision.policy, .allow)
            XCTAssertNil(decision.resolution)
        }

        func test_policy_unsafeBypass_allowsDebugDataURL() throws {
            // DEBUG-only escape hatch: instrumented tests / mock backend can
            // load the challenge from a `data:` URL. With the bypass set, the
            // unsafe gate must NOT fire — otherwise the demo can't reach the
            // mocked challenge page.
            let url = try XCTUnwrap(URL(string: "data:text/html,<h1>fake</h1>"))
            let decision = threeDSWebViewPolicy(
                for: url,
                isMainFrame: true,
                isResolved: false,
                bypassUnsafeNavigation: true,
                returnMatcher: returnMatcher,
                cancelMatcher: cancelMatcher,
                merchantReturnURL: nil
            )
            XCTAssertEqual(decision.policy, .allow)
            XCTAssertNil(decision.resolution)
        }

        func test_policy_arbitraryHttpsHost_allows() throws {
            // Default path: a typical issuer ACS URL is just allowed —
            // matchers don't fire, no resolution emitted.
            let url = try XCTUnwrap(URL(string: "https://acs.bank.example/challenge"))
            let decision = threeDSWebViewPolicy(
                for: url,
                isMainFrame: true,
                isResolved: false,
                returnMatcher: returnMatcher,
                cancelMatcher: cancelMatcher,
                merchantReturnURL: URL(string: "https://merchant.example.com/return")
            )
            XCTAssertEqual(decision.policy, .allow)
            XCTAssertNil(decision.resolution)
        }

        // MARK: - Phase 1: scheme-aware merchant-return arm + openExternalURL

        func test_policy_customScheme_exactMatch_cancelsAndResolvesWithOpenURL() throws {
            // Custom-scheme merchant return URL (deep link back to merchant
            // app). Exact nav-URL match → cancel + `.authenticated` + surface
            // the URL via `openExternalURL` so the presenter can fire
            // `UIApplication.open` from the call site (policy stays pure).
            let merchantReturnURL = try XCTUnwrap(URL(string: "myapp://order/123"))
            let decision = threeDSWebViewPolicy(
                for: merchantReturnURL,
                isMainFrame: true,
                isResolved: false,
                returnMatcher: returnMatcher,
                cancelMatcher: cancelMatcher,
                merchantReturnURL: merchantReturnURL
            )
            XCTAssertEqual(decision.policy, .cancel)
            XCTAssertEqual(decision.resolution, .authenticated)
            XCTAssertEqual(decision.openExternalURL, merchantReturnURL)
        }

        func test_policy_customScheme_prefixMatch_cancelsAndResolvesWithOpenURL() throws {
            // Custom-scheme prefix match — the ACS may append query params
            // (`?status=ok`) to the registered deep link. Prefix-match keeps
            // the merchant handoff intact even if the registered URL is the
            // unparameterised base.
            let merchantReturnURL = try XCTUnwrap(URL(string: "myapp://order/123"))
            let navURL = try XCTUnwrap(URL(string: "myapp://order/123?status=ok"))
            let decision = threeDSWebViewPolicy(
                for: navURL,
                isMainFrame: true,
                isResolved: false,
                returnMatcher: returnMatcher,
                cancelMatcher: cancelMatcher,
                merchantReturnURL: merchantReturnURL
            )
            XCTAssertEqual(decision.policy, .cancel)
            XCTAssertEqual(decision.resolution, .authenticated)
            XCTAssertEqual(decision.openExternalURL, merchantReturnURL)
        }

        func test_policy_customScheme_noMatch_allows() throws {
            // Custom-scheme nav that does NOT match the registered merchant
            // return URL must fall through to `.allow` — the policy treats
            // unknown deep-link targets as legitimate ACS-controlled flow,
            // not as a presentation-done signal.
            let merchantReturnURL = try XCTUnwrap(URL(string: "myapp://order/123"))
            let navURL = try XCTUnwrap(URL(string: "myapp://other/456"))
            let decision = threeDSWebViewPolicy(
                for: navURL,
                isMainFrame: true,
                isResolved: false,
                returnMatcher: returnMatcher,
                cancelMatcher: cancelMatcher,
                merchantReturnURL: merchantReturnURL
            )
            XCTAssertEqual(decision.policy, .allow)
            XCTAssertNil(decision.resolution)
            XCTAssertNil(decision.openExternalURL)
        }

        func test_policy_httpsReturnURL_hostMatch_cancelsNoOpenURL() throws {
            // HTTPS merchant return URL → host-only equality (case-
            // insensitive). Backward-compatible with the prior host-only
            // arm — `openExternalURL` stays nil because WebKit can render
            // the page; no UIApplication.open handoff is needed.
            let merchantReturnURL = try XCTUnwrap(URL(string: "https://example.com/return"))
            let navURL = try XCTUnwrap(URL(string: "https://example.com/return"))
            let decision = threeDSWebViewPolicy(
                for: navURL,
                isMainFrame: true,
                isResolved: false,
                returnMatcher: returnMatcher,
                cancelMatcher: cancelMatcher,
                merchantReturnURL: merchantReturnURL
            )
            XCTAssertEqual(decision.policy, .cancel)
            XCTAssertEqual(decision.resolution, .authenticated)
            XCTAssertNil(decision.openExternalURL)
        }

        func test_policy_httpsReturnURL_hostMismatch_allows() throws {
            // HTTPS merchant return URL + nav to a different host → allow.
            // A registered return URL on example.com must NOT swallow a nav
            // to attacker.com just because the URL was main-frame; the host
            // gate is the security boundary.
            let merchantReturnURL = try XCTUnwrap(URL(string: "https://example.com/return"))
            let navURL = try XCTUnwrap(URL(string: "https://attacker.com/return"))
            let decision = threeDSWebViewPolicy(
                for: navURL,
                isMainFrame: true,
                isResolved: false,
                returnMatcher: returnMatcher,
                cancelMatcher: cancelMatcher,
                merchantReturnURL: merchantReturnURL
            )
            XCTAssertEqual(decision.policy, .allow)
            XCTAssertNil(decision.resolution)
            XCTAssertNil(decision.openExternalURL)
        }

        // MARK: - postMessage allow-list generation

        func test_postMessageAllowedHosts_includesAllExpectedRelayHosts() throws {
            let challengeURL = try XCTUnwrap(URL(string: "https://acs.bank.example/challenge"))
            let hosts = threeDSPostMessageAllowedHosts(challengeURL: challengeURL)
            XCTAssertEqual(hosts.first, "acs.bank.example", "challenge host must lead the allow-list")
            // Mollie's documented relay hosts — every one must appear EXPLICITLY.
            XCTAssertTrue(hosts.contains("secure-3ds.mollie.com"))
            XCTAssertTrue(hosts.contains("pay.mollie.nl"))
            XCTAssertTrue(hosts.contains("pay.mollie.com"))
            XCTAssertTrue(hosts.contains("www.mollie.com"))
            XCTAssertTrue(hosts.contains("mollie.com"))
        }

        func test_postMessageAllowedHosts_dedupesChallengeHostWhenAlreadyKnown() throws {
            // If the challenge happens to be served from a known relay host,
            // we mustn't list it twice.
            let challengeURL = try XCTUnwrap(URL(string: "https://secure-3ds.mollie.com/challenge"))
            let hosts = threeDSPostMessageAllowedHosts(challengeURL: challengeURL)
            XCTAssertEqual(
                hosts.filter { $0 == "secure-3ds.mollie.com" }.count,
                1,
                "Challenge host that matches a known relay must appear exactly once"
            )
        }

        func test_makeBridgeJS_containsExplicitHosts_andNoWildcard() throws {
            // The wildcard `.mollie.com` endsWith check is GONE. The
            // generated JS must reference each trusted host literally and use
            // `indexOf` against the allow-list, NOT a substring/suffix check.
            let challengeURL = try XCTUnwrap(URL(string: "https://acs.bank.example/challenge"))
            let json = threeDSPostMessageAllowedHostsJSON(challengeURL: challengeURL)
            let jsSource = makeThreeDSBridgeJS(allowedHostsJSON: json)

            XCTAssertTrue(
                jsSource.contains("\"secure-3ds.mollie.com\""),
                "JS must include canonical 3DS relay host literally"
            )
            XCTAssertTrue(jsSource.contains("\"pay.mollie.nl\""))
            XCTAssertTrue(jsSource.contains("\"pay.mollie.com\""))
            XCTAssertTrue(jsSource.contains("\"acs.bank.example\""), "JS must include challenge host")
            XCTAssertTrue(
                jsSource.contains("allowedHosts.indexOf(originHost)"),
                "JS must use exact-match indexOf check"
            )

            // Adversarial: the OLD code did `endsWith('.mollie.com')` — a
            // leading dot literal was the smoking gun for the wildcard-
            // subdomain bypass. It MUST NOT appear in the generated JS.
            XCTAssertFalse(
                jsSource.contains("'.mollie.com'"),
                "Wildcard `.mollie.com` substring/suffix must not appear"
            )
            XCTAssertFalse(
                jsSource.contains("\".mollie.com\""),
                "Wildcard `.mollie.com` substring/suffix must not appear"
            )
            XCTAssertFalse(jsSource.contains("endsWith"), "endsWith origin check was the bypass vector — must be gone")
        }

        func test_jsonEscapeHosts_producesValidJSONArrayLiteral() {
            // The output is interpolated into a JS source string as
            // `var allowedHosts = …;` — must be a syntactically valid JSON
            // array OR `[]` on encoding failure. Quotes and brackets matter.
            let out = threeDSJSONEscapeHosts(["a.example", "b.example"])
            XCTAssertEqual(out, "[\"a.example\",\"b.example\"]")
        }
    }
#endif

#if canImport(UIKit) && canImport(WebKit)
    import UIKit

    /// Verifies the controller releases its strong references into the
    /// `WKUserContentController` graph on deinit. WebKit retains script
    /// message handlers and injected user scripts for the lifetime of the
    /// configuration; failing to remove them keeps the controller (and any
    /// captured state) alive past the merchant's expected scope.
    @MainActor
    final class ThreeDSWebViewControllerTests: XCTestCase {
        func test_deinit_removesScriptMessageHandlerAndUserScripts() throws {
            let url = try XCTUnwrap(URL(string: "https://example.com/challenge"))
            var controller: ThreeDSWebViewController? = ThreeDSWebViewController(challengeURL: url)
            // Trigger viewDidLoad — the configuration / handler / scripts are
            // wired up there, not in init.
            _ = controller?.view

            // Capture the configuration so we can inspect it after deinit.
            // Using a weak ref proves the WebView itself is reclaimed; the
            // configuration is captured strongly here because we own the test.
            let webView = try XCTUnwrap(try Mirror(reflecting: XCTUnwrap(controller))
                .descendant("webView") as? WKWebView)
            let ucc = webView.configuration.userContentController

            // Sanity: the bridge script and handler are installed.
            XCTAssertEqual(ucc.userScripts.count, 1, "Expected exactly one injected user script after viewDidLoad")

            // Drop the controller — deinit must remove the handler and scripts.
            controller = nil

            XCTAssertEqual(
                ucc.userScripts.count,
                0,
                "Deinit must call removeAllUserScripts() to break the WKUserContentController retain cycle"
            )
            // No public API to enumerate handler names; the best we can do is
            // re-add and confirm no duplicate-add NSException fires. WebKit
            // raises NSInvalidArgumentException if the name is still bound.
            let probe = ProbeHandler()
            XCTAssertNoThrow(
                ucc.add(probe, name: "mollieChallenge"),
                "Adding handler under same name must not throw — confirms deinit removed it"
            )
            ucc.removeScriptMessageHandler(forName: "mollieChallenge")
        }

        // MARK: - Deferred reveal (heuristic) — epic t330

        func test_viewDidLoad_hidesWebViewBehindAuthenticatingCover() throws {
            let url = try XCTUnwrap(URL(string: "https://example.com/challenge"))
            // Large revealDelay so the deferred reveal can't fire mid-test.
            let controller = ThreeDSWebViewController(challengeURL: url, revealPolicy: .challengeDriven(watchdog: 1000))
            _ = controller.view
            let webView = try XCTUnwrap(Mirror(reflecting: controller).descendant("webView") as? WKWebView)
            let cover = try XCTUnwrap(Mirror(reflecting: controller).descendant("coverView") as? UIView)
            XCTAssertTrue(controller.view.subviews.contains(cover), "Authenticating cover must be in the hierarchy")
            XCTAssertEqual(controller.view.subviews.last, cover, "Cover must sit above the WebView")
            XCTAssertTrue(
                webView.accessibilityElementsHidden,
                "WebView must be hidden from assistive tech while covered"
            )
            XCTAssertTrue(
                cover.subviews.contains { $0 is UIActivityIndicatorView },
                "Cover must show an activity indicator"
            )
        }

        func test_revealWebView_restoresWebViewAccessibility() throws {
            let url = try XCTUnwrap(URL(string: "https://example.com/challenge"))
            let controller = ThreeDSWebViewController(challengeURL: url, revealPolicy: .challengeDriven(watchdog: 1000))
            _ = controller.view
            let webView = try XCTUnwrap(Mirror(reflecting: controller).descendant("webView") as? WKWebView)
            XCTAssertTrue(webView.accessibilityElementsHidden)
            controller.revealWebView()
            XCTAssertFalse(
                webView.accessibilityElementsHidden,
                "Revealing the challenge must expose the WebView to assistive tech"
            )
        }

        func test_cancelButton_resolvesCancelled_andBlocksLaterReveal() throws {
            let url = try XCTUnwrap(URL(string: "https://example.com/challenge"))
            let controller = ThreeDSWebViewController(challengeURL: url, revealPolicy: .challengeDriven(watchdog: 1000))
            _ = controller.view
            var result: ThreeDSResult?
            controller.onResult = { result = $0 }
            let webView = try XCTUnwrap(Mirror(reflecting: controller).descendant("webView") as? WKWebView)
            let cover = try XCTUnwrap(Mirror(reflecting: controller).descendant("coverView") as? UIView)
            let cancel = try XCTUnwrap(Self.firstButton(in: cover), "Cover must expose a Cancel button")

            cancel.sendActions(for: .touchUpInside)
            XCTAssertEqual(result, .cancelled, "Cancel must resolve the flow as cancelled")

            // Once resolved, a later (timer-driven) reveal must be a no-op so a
            // frictionless / cancelled flow never flashes the raw WebView.
            controller.revealWebView()
            XCTAssertTrue(
                webView.accessibilityElementsHidden,
                "Reveal after resolution must be a no-op"
            )
        }

        // MARK: - Event-driven reveal (epic t338)

        func test_receiveChallengeEscalation_revealsWebView() throws {
            // A genuine `challenge` escalation from the interceptor means the
            // issuer is presenting an interactive challenge — the cover must
            // lift immediately, independent of the watchdog.
            let url = try XCTUnwrap(URL(string: "https://example.com/challenge"))
            let controller = ThreeDSWebViewController(
                challengeURL: url,
                revealPolicy: .challengeDriven(watchdog: 1000)
            )
            _ = controller.view
            let webView = try XCTUnwrap(Mirror(reflecting: controller).descendant("webView") as? WKWebView)
            XCTAssertTrue(webView.accessibilityElementsHidden)
            controller.receive(.challengeEscalation)
            XCTAssertFalse(
                webView.accessibilityElementsHidden,
                "A challenge escalation must reveal the WebView immediately"
            )
        }

        func test_receiveCompleteBeforeChallenge_resolvesAuthenticated_withoutRevealing() throws {
            // The frictionless-within-challenge case: the ACS auto-completes and
            // emits `complete` with NO preceding `challenge`. The flow must
            // resolve `.authenticated` while the cover stays up — the user never
            // sees the raw interceptor page.
            let url = try XCTUnwrap(URL(string: "https://example.com/challenge"))
            let controller = ThreeDSWebViewController(
                challengeURL: url,
                revealPolicy: .challengeDriven(watchdog: 1000)
            )
            _ = controller.view
            var result: ThreeDSResult?
            controller.onResult = { result = $0 }
            let webView = try XCTUnwrap(Mirror(reflecting: controller).descendant("webView") as? WKWebView)

            controller.receive(.result(.authenticated))

            XCTAssertEqual(result, .authenticated, "A terminal complete must resolve the flow")
            XCTAssertTrue(
                webView.accessibilityElementsHidden,
                "Frictionless complete (no preceding challenge) must NOT reveal the WebView"
            )
        }

        func test_noEventWithinWatchdog_revealsViaWatchdog() async throws {
            // Safety backstop: if a genuinely interactive page never emits a
            // `challenge` (or the interceptor is broken/silent), the long
            // watchdog must still reveal the WebView so the flow can't hang
            // invisibly forever.
            let url = try XCTUnwrap(URL(string: "https://example.com/challenge"))
            let controller = ThreeDSWebViewController(
                challengeURL: url,
                revealPolicy: .challengeDriven(watchdog: 0.05)
            )
            _ = controller.view
            let webView = try XCTUnwrap(Mirror(reflecting: controller).descendant("webView") as? WKWebView)
            XCTAssertTrue(webView.accessibilityElementsHidden)

            try await Task.sleep(nanoseconds: 300_000_000)

            XCTAssertFalse(
                webView.accessibilityElementsHidden,
                "Watchdog must reveal the WebView when no challenge event ever arrives"
            )
        }

        func test_receiveResultFailed_resolvesFailed() throws {
            let url = try XCTUnwrap(URL(string: "https://example.com/challenge"))
            let controller = ThreeDSWebViewController(
                challengeURL: url,
                revealPolicy: .challengeDriven(watchdog: 1000)
            )
            _ = controller.view
            var result: ThreeDSResult?
            controller.onResult = { result = $0 }
            controller.receive(.result(.failed(reason: .challengeFailed)))
            XCTAssertEqual(result, .failed(reason: .challengeFailed))
        }

        func test_receiveResultCancelled_resolvesCancelled() throws {
            let url = try XCTUnwrap(URL(string: "https://example.com/challenge"))
            let controller = ThreeDSWebViewController(
                challengeURL: url,
                revealPolicy: .challengeDriven(watchdog: 1000)
            )
            _ = controller.view
            var result: ThreeDSResult?
            controller.onResult = { result = $0 }
            controller.receive(.result(.cancelled))
            XCTAssertEqual(result, .cancelled)
        }

        func test_challengeEscalation_doesNotTripResolveGuard() throws {
            // The non-terminal challenge must not satisfy the single-shot
            // `resolved` guard — a terminal result arriving afterwards must
            // still resolve the flow.
            let url = try XCTUnwrap(URL(string: "https://example.com/challenge"))
            let controller = ThreeDSWebViewController(
                challengeURL: url,
                revealPolicy: .challengeDriven(watchdog: 1000)
            )
            _ = controller.view
            var result: ThreeDSResult?
            controller.onResult = { result = $0 }

            controller.receive(.challengeEscalation)
            XCTAssertNil(result, "Challenge escalation is non-terminal and must not resolve")

            controller.receive(.result(.authenticated))
            XCTAssertEqual(
                result,
                .authenticated,
                "A terminal result after a challenge escalation must still resolve"
            )
        }

        // MARK: - Present-on-demand (epic t338): no screen unless a challenge needs it

        func test_presentOnDemand_installsNoCover() throws {
            let url = try XCTUnwrap(URL(string: "https://example.com/challenge"))
            let controller = ThreeDSWebViewController(
                challengeURL: url,
                revealPolicy: .challengeDriven(watchdog: 1000),
                presentOnDemand: true
            )
            _ = controller.view
            XCTAssertNil(
                Mirror(reflecting: controller).descendant("coverView") as? UIView,
                "Present-on-demand hosts the WebView off-screen — no in-place cover"
            )
        }

        func test_presentOnDemand_challengeEscalation_requestsPresentation() throws {
            let url = try XCTUnwrap(URL(string: "https://example.com/challenge"))
            let controller = ThreeDSWebViewController(
                challengeURL: url,
                revealPolicy: .challengeDriven(watchdog: 1000),
                presentOnDemand: true
            )
            var requested = false
            controller.onNeedsPresentation = { requested = true }
            _ = controller.view

            controller.receive(.challengeEscalation)

            XCTAssertTrue(requested, "A challenge escalation must ask the coordinator to present")
            XCTAssertTrue(controller.hasRequestedPresentation)
        }

        func test_presentOnDemand_completeBeforeChallenge_resolvesWithoutPresenting() throws {
            // The frictionless case: a terminal complete with no preceding
            // challenge must resolve `.authenticated` and NEVER ask to present —
            // so the user sees no intermediary screen.
            let url = try XCTUnwrap(URL(string: "https://example.com/challenge"))
            let controller = ThreeDSWebViewController(
                challengeURL: url,
                revealPolicy: .challengeDriven(watchdog: 1000),
                presentOnDemand: true
            )
            var result: ThreeDSResult?
            var requested = false
            controller.onResult = { result = $0 }
            controller.onNeedsPresentation = { requested = true }
            _ = controller.view

            controller.receive(.result(.authenticated))

            XCTAssertEqual(result, .authenticated)
            XCTAssertFalse(requested, "Frictionless complete must NOT present anything")
            XCTAssertFalse(controller.hasRequestedPresentation)
        }

        func test_presentOnDemand_watchdog_requestsPresentation() async throws {
            // Backstop: if no event ever arrives, the watchdog must surface the
            // controller so the flow can't hang invisibly.
            let url = try XCTUnwrap(URL(string: "https://example.com/challenge"))
            let controller = ThreeDSWebViewController(
                challengeURL: url,
                revealPolicy: .challengeDriven(watchdog: 0.05),
                presentOnDemand: true
            )
            var requested = false
            controller.onNeedsPresentation = { requested = true }
            _ = controller.view

            try await Task.sleep(nanoseconds: 300_000_000)

            XCTAssertTrue(requested, "Watchdog must request presentation when no event arrives")
        }

        private static func firstButton(in view: UIView) -> UIButton? {
            for sub in view.subviews {
                if let button = sub as? UIButton {
                    return button
                }
                if let found = firstButton(in: sub) {
                    return found
                }
            }
            return nil
        }

        private final class ProbeHandler: NSObject, WKScriptMessageHandler {
            func userContentController(_: WKUserContentController, didReceive _: WKScriptMessage) {}
        }
    }
#endif
