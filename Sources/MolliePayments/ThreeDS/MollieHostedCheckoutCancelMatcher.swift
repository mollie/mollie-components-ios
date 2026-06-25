import Foundation

/// Detects when the Mollie hosted 3DS page (e.g.
/// `pay.mollie.nl/payment/prepare-authentication/<id>`) has dismissed itself
/// by navigating the top frame to the Mollie hosted checkout return URL with
/// an `error_code` query parameter — the signal Mollie's hosted page emits
/// after the user clicks ANNULEREN.
///
/// Why URL-pattern detection rather than postMessage: the hosted page is
/// loaded standalone in our WKWebView (not iframed inside `js.mollie.com`),
/// so the web SDK's `mollie-interceptor` postMessage protocol — which only
/// emits `challenge`/`complete`/`error` — never sees the cancel branch. The
/// hosted page implements its own confirm dialog and then redirects.
package struct MollieHostedCheckoutCancelMatcher {
    private static let allowedHosts: Set<String> = ["www.mollie.com", "mollie.com"]
    private static let pathPrefix = "/checkout/"
    /// Mollie's documented return code for "Authorisation cancelled by
    /// cardholder". All other codes surface as `.failed` so a real ACS
    /// decline isn't mistaken for a user-initiated cancel.
    private static let cancelledErrorCode = "1008"

    package init() {}

    package func matches(_ url: URL) -> Bool {
        guard url.scheme == "https" else { return false }
        guard let host = url.host?.lowercased(), Self.allowedHosts.contains(host) else { return false }
        guard url.path.hasPrefix(Self.pathPrefix) else { return false }
        return errorCode(in: url) != nil
    }

    package func parseResult(from url: URL) -> ThreeDSResult {
        guard let code = errorCode(in: url) else {
            return .failed(reason: .challengeFailed)
        }
        return code == Self.cancelledErrorCode
            ? .cancelled
            : .failed(reason: .sdkError(message: "mollie_error_\(code)"))
    }

    private func errorCode(in url: URL) -> String? {
        let raw = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "error_code" })?
            .value
        // Empty-string param (`?error_code=`) carries no signal — treat as
        // absent. Otherwise `parseResult` would surface `mollie_error_` with
        // no code, a useless diagnostic that masks the real "no signal" state.
        guard let raw, !raw.isEmpty else { return nil }
        return raw
    }
}
