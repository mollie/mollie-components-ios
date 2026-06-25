#if canImport(WebKit)
    import WebKit
    import XCTest
    @testable import MolliePayments

    /// Unit tests for the pure policy + JS-bridge helpers extracted from
    /// `ThreeDSWebViewController` (FIX #26 / FIX #12). Gated on WebKit only
    /// (not UIKit) so the assertions run on macOS as well as iOS — the
    /// controller class itself stays UIKit-only and its `deinit` test lives
    /// further down behind the stricter gate.
    final class ThreeDSWebViewPolicyTests: XCTestCase {
        // MARK: - FIX #26: threeDSWebViewPolicy(for:…) extracted helper

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
            // FIX #18 guard relies on FIX #26 wiring — verify the chain end-to-end.
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
            // FIX #18: empty `?error_code=` must NOT match the cancel matcher
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

        // MARK: - FIX #12: postMessage allow-list generation

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
            // FIX #12: the wildcard `.mollie.com` endsWith check is GONE. The
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

        private final class ProbeHandler: NSObject, WKScriptMessageHandler {
            func userContentController(_: WKUserContentController, didReceive _: WKScriptMessage) {}
        }
    }
#endif
