#if canImport(WebKit)
    import Foundation
    import MollieCore
    import WebKit

    // Pure policy + JS helpers extracted from `ThreeDSWebViewController` so
    // they can be unit-tested on every platform the package supports — the
    // controller itself is gated on `UIKit` (iOS only) and would otherwise
    // keep these branches invisible to `swift test` on macOS.
    //
    // Nothing here owns mutable state. Every input the live `decidePolicyFor`
    // reads off the navigation action / instance is threaded through as a
    // parameter so adversarial cases (`javascript:`, `http://`, iframe nav
    // to a return URL, cancel matcher with empty `error_code`, etc.) can be
    // exercised without standing up a `WKWebView`.

    /// Result of `threeDSWebViewPolicy(for:…)` — the WebKit policy + the
    /// optional 3DS resolution to emit on this navigation. Splitting these
    /// keeps the caller free of branching logic and lets unit tests assert
    /// on a pure, deterministic shape.
    package struct ThreeDSPolicyDecision: Equatable {
        package let policy: WKNavigationActionPolicy
        package let resolution: ThreeDSResult?
        /// When non-nil, the caller must dispatch this URL via
        /// `UIApplication.open` (deep-link handoff back to the merchant app).
        /// Only set by the custom-scheme merchant-return arm; nil for every
        /// other branch. Policy stays pure — no UIKit here.
        package let openExternalURL: URL?

        package init(
            policy: WKNavigationActionPolicy,
            resolution: ThreeDSResult? = nil,
            openExternalURL: URL? = nil
        ) {
            self.policy = policy
            self.resolution = resolution
            self.openExternalURL = openExternalURL
        }
    }

    /// Pure navigation-policy decision. Mirrors `decidePolicyFor` branching
    /// but takes every input explicitly.
    ///
    /// Order of evaluation matters and matches the live delegate:
    ///   1. Main-frame nav to a custom-scheme `merchantReturnURL` (e.g.
    ///      `myapp://…`) with prefix-match → cancel + `.authenticated` +
    ///      `openExternalURL = merchantReturnURL`. Evaluated BEFORE the
    ///      unsafe-navigation gate because the merchant explicitly opted in
    ///      to this deep-link target; the caller will dispatch it via
    ///      `UIApplication.open`, not load it in the WebView.
    ///   2. Unsafe URL → cancel + `.failed(sdkError)`. Stops here; later
    ///      branches must not run on attacker-controlled inputs. Narrow
    ///      exemption: a nav URL whose scheme equals the merchant's own
    ///      registered custom scheme falls through (didn't prefix-match
    ///      step 1, so iOS — not us — handles it).
    ///   3. Already-resolved → always allow (let WebKit settle pending
    ///      navs without re-resolving).
    ///   4. Iframe nav → allow (only top-level matters for resolution).
    ///   5. Main-frame nav to `returnMatcher` → cancel + parsed result.
    ///   6. Main-frame nav to `cancelMatcher` → cancel + parsed result
    ///      (1008 → cancelled, else failed).
    ///   7. Main-frame nav to an http/https `merchantReturnURL` (host
    ///      equality, case-insensitive) → cancel + `.authenticated`
    ///      (presentation done; poller resumes; no `openExternalURL`).
    ///   8. Default → allow.
    package func threeDSWebViewPolicy( // swiftlint:disable:this function_parameter_count
        for url: URL?,
        isMainFrame: Bool,
        isResolved: Bool,
        bypassUnsafeNavigation: Bool = false,
        returnMatcher: ThreeDSReturnURLMatcher,
        cancelMatcher: MollieHostedCheckoutCancelMatcher,
        merchantReturnURL: URL?
    ) -> ThreeDSPolicyDecision {
        // Custom-scheme merchant-return URL the merchant explicitly opted
        // into on this session (e.g. `myapp://order/123`). Determined once
        // up-front so both the prefix-match arm and the unsafe-nav
        // exemption agree on the registered scheme.
        let merchantCustomScheme: String? = {
            guard let scheme = merchantReturnURL?.scheme?.lowercased(),
                  scheme != "http", scheme != "https"
            else { return nil }
            return scheme
        }()

        // Custom-scheme merchant-return arm. Evaluated BEFORE the unsafe-
        // navigation gate because `isUnsafeNavigation` rejects every
        // non-https scheme — including the merchant's own deep-link
        // target. Prefix-match accommodates an ACS appending query params
        // (`?status=ok`) to the registered base. Main-frame + not-yet-
        // resolved only; iframes and post-resolution navs fall through to
        // the existing gates below.
        // swiftlint:disable opening_brace
        if isMainFrame,
           !isResolved,
           let url,
           let merchantReturnURL,
           merchantCustomScheme != nil,
           url.absoluteString.hasPrefix(merchantReturnURL.absoluteString)
        {
            return ThreeDSPolicyDecision(
                policy: .cancel,
                resolution: .authenticated,
                openExternalURL: merchantReturnURL
            )
        }
        // swiftlint:enable opening_brace

        // Safety: block plaintext HTTP (downgrade), non-https schemes, and
        // private-network destinations BEFORE any return-URL check so a
        // malicious ACS cannot exfiltrate the session by redirecting to an
        // attacker-controlled HTTP endpoint or scanning the user's LAN.
        //
        // Two escape hatches:
        //   - DEBUG `bypassUnsafeNavigation` — demo / instrumented tests
        //     serving a challenge from `data:`. GONE in Release.
        //   - Merchant-registered custom scheme — a nav URL whose scheme
        //     matches the merchant's own registered deep-link scheme is
        //     allowed through. Did not match the prefix arm above so we
        //     won't dispatch `UIApplication.open`; iOS handles the
        //     navigation itself (open-in-other-app or fail). Scope is
        //     narrow: ONLY the scheme the merchant put on the session.
        let navScheme = url?.scheme?.lowercased()
        let isMerchantCustomScheme = merchantCustomScheme != nil && navScheme == merchantCustomScheme
        if let url, isUnsafeNavigation(url: url), !bypassUnsafeNavigation, !isMerchantCustomScheme {
            return ThreeDSPolicyDecision(
                policy: .cancel,
                resolution: .failed(reason: .sdkError(message: "Unsafe navigation blocked"))
            )
        }

        // Already-resolved: WebKit may still emit policy decisions for
        // in-flight navs after we've signalled the result. Allow them —
        // re-resolving is a no-op anyway (resolve() guards on `resolved`).
        if isResolved {
            return ThreeDSPolicyDecision(policy: .allow)
        }

        // Iframe nav must NOT resolve. The ACS page can embed arbitrary
        // iframes; one of them pointing at `…/3ds/return?status=authenticated`
        // would otherwise let an attacker bypass the challenge entirely.
        guard isMainFrame else {
            return ThreeDSPolicyDecision(policy: .allow)
        }

        guard let url else {
            return ThreeDSPolicyDecision(policy: .allow)
        }

        // Main-frame nav to the ACS-back-to-Mollie return URL → finished.
        if returnMatcher.matches(url) {
            return ThreeDSPolicyDecision(policy: .cancel, resolution: returnMatcher.parseResult(from: url))
        }

        // Cancel/abort from the Mollie hosted 3DS page (ANNULEREN link →
        // confirm → top-frame redirect to www.mollie.com/checkout/credit-
        // card/return?error_code=…). 1008 → cancelled; any other code →
        // failed with a stable `mollie_error_<code>` token.
        if cancelMatcher.matches(url) {
            return ThreeDSPolicyDecision(policy: .cancel, resolution: cancelMatcher.parseResult(from: url))
        }

        // HTTP/HTTPS merchant-return match for the `redirect` actionType
        // flow. `.authenticated` here means "presentation finished"; the
        // coordinator resumes polling to discover the actual paid/failed
        // outcome. Case-insensitive host equality only (backward-compatible
        // with the prior host-string arm); no `openExternalURL` because
        // WebKit can render the page in-process.
        // swiftlint:disable opening_brace
        if let merchantReturnURL,
           let scheme = merchantReturnURL.scheme?.lowercased(),
           scheme == "http" || scheme == "https",
           let returnHost = merchantReturnURL.host?.lowercased(),
           let navHost = url.host?.lowercased(),
           navHost == returnHost
        {
            return ThreeDSPolicyDecision(policy: .cancel, resolution: .authenticated)
        }
        // swiftlint:enable opening_brace

        return ThreeDSPolicyDecision(policy: .allow)
    }

    // MARK: - postMessage bridge JS

    /// JSON-encode a Swift array of strings for safe interpolation into JS
    /// source. Falls back to `[]` on any encoding failure.
    package func threeDSJSONEscapeHosts(_ values: [String]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: values, options: []),
              let str = String(data: data, encoding: .utf8)
        else { return "[]" }
        return str
    }

    /// Mollie's documented 3DS relay hosts plus the challenge issuer host.
    /// Order is stable so JSON output is deterministic for tests. No
    /// `*.mollie.com` wildcard — any new host must be added here EXPLICITLY.
    ///
    /// Hosts:
    ///   - challenge URL host (the issuer ACS).
    ///   - `secure-3ds.mollie.com` (canonical 3DS relay).
    ///   - `pay.mollie.nl`, `pay.mollie.com` (hosted prepare-authentication).
    ///   - `www.mollie.com`, `mollie.com` (hosted checkout return / cancel).
    package func threeDSPostMessageAllowedHosts(challengeURL: URL) -> [String] {
        var hosts: [String] = []
        if let host = challengeURL.host?.lowercased(), !host.isEmpty {
            hosts.append(host)
        }
        for known in [
            "secure-3ds.mollie.com",
            "pay.mollie.nl",
            "pay.mollie.com",
            "www.mollie.com",
            "mollie.com",
        ] where !hosts.contains(known) {
            hosts.append(known)
        }
        return hosts
    }

    /// JSON array literal of the postMessage host allow-list, ready to
    /// drop into the bridge JS as `var allowedHosts = …;`.
    package func threeDSPostMessageAllowedHostsJSON(challengeURL: URL) -> String {
        threeDSJSONEscapeHosts(threeDSPostMessageAllowedHosts(challengeURL: challengeURL))
    }

    /// The injected postMessage-bridge JS, parameterized on the allow-list
    /// JSON array.
    ///
    /// CONTRACT: the JS function relies on exact host equality only. Do not
    /// add `endsWith()` / `indexOf(.) !== 0` style matches here — they re-
    /// introduce the wildcard-subdomain bypass we previously removed. Any
    /// new Mollie host that needs to postMessage must be added to
    /// `threeDSPostMessageAllowedHosts(challengeURL:)` instead.
    package func makeThreeDSBridgeJS(allowedHostsJSON: String) -> String {
        """
        (function() {
          var allowedHosts = \(allowedHostsJSON);
          window.addEventListener('message', function(e) {
            // Same-origin shortcut: a message whose source window is this
            // window cannot have been injected by an attacker (different
            // origins live in different windows). Skip origin parsing
            // entirely so we don't throw on pages whose origin string is
            // not a parseable URL (e.g. `data:` pages where e.origin is
            // the literal string "null").
            var sameOrigin = e.source === window;
            if (!sameOrigin) {
              var originHost = '';
              try {
                originHost = e.origin ? new URL(e.origin).host : '';
              } catch (_) { return; /* malformed cross-origin → drop */ }
              if (allowedHosts.indexOf(originHost) === -1) { return; }
            }
            if (e.data && e.data.sender === 'mollie-interceptor') {
              window.webkit.messageHandlers.mollieChallenge.postMessage(e.data);
            }
          }, false);
        })();
        """
    }

#endif
