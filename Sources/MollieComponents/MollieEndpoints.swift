import Foundation
import MollieCore

/// Override the Mollie service endpoints the checkout flow routes through.
///
/// Default values point at the production hosts — `sessions.mollie.com`
/// and `api.cc.mollie.com`. Merchants integrating against production
/// don't need to construct this type; the standard
/// `MollieCheckout.presentCard(from:)` and `MollieCardComponent`
/// entry points use the defaults automatically.
///
/// **When you DO need this:** to point the checkout at a non-production
/// Mollie host — for example a test/sandbox environment or a local
/// development server.
///
/// **What `testmode` does instead:** the `testmode` bit on the decoded
/// `clientToken` already routes test-vs-live payment processing on the
/// production hosts. You do NOT need `MollieEndpoints` to test
/// card payments against production Mollie — pass a test-mode
/// `clientToken` and you're done.
public struct MollieEndpoints: @unchecked Sendable {
    /// Base URL of the Sessions Service the sheet talks to for session
    /// state and polling. Defaults to the production host in `.production`.
    public let sessionsBaseURL: URL
    /// Base URL of the PCI card tokeniser the sheet posts card data to in
    /// exchange for a single-use token. Defaults to the production host in
    /// `.production`.
    public let tokenizerBaseURL: URL

    /// URLSession used by the sheet's HTTP clients. `.production` uses a
    /// tuned session (bounded request/resource timeouts + connectivity
    /// waiting — see `tunedProductionConfiguration()`) whose delegate
    /// additionally enforces SPKI pinning against `productionPins` (see
    /// `PublicKeyPinner`); callers targeting a non-production host can pass
    /// a session configured to trust that host instead (e.g. one backed by
    /// a delegate that accepts a development server's self-signed cert) —
    /// dev/custom endpoints are unpinned by design.
    ///
    /// The struct is `@unchecked Sendable` because `URLSession` is a
    /// reference type that the compiler can't prove is Sendable in all
    /// configurations; in practice, URLSession is documented thread-safe
    /// and the value is hand-constructed once per sheet presentation.
    public let urlSession: URLSession

    init(
        sessionsBaseURL: URL,
        tokenizerBaseURL: URL,
        urlSession: URLSession = .shared
    ) {
        self.sessionsBaseURL = sessionsBaseURL
        self.tokenizerBaseURL = tokenizerBaseURL
        self.urlSession = urlSession
    }

    /// Production Mollie hosts. The default used by the standard sheet
    /// entry point.
    public static let production = MollieEndpoints(
        sessionsBaseURL: URL(string: "https://sessions.mollie.com")!,
        tokenizerBaseURL: URL(string: "https://api.cc.mollie.com")!,
        urlSession: URLSession(
            configuration: tunedProductionConfiguration(),
            delegate: PinningURLSessionDelegate(
                pinner: PublicKeyPinner(pins: productionPins, expiry: productionPinExpiry, now: Date.init)
            ),
            delegateQueue: nil
        )
    )

    /// Base64 SPKI-SHA256 pins for the Google Trust Services chain that
    /// issues certificates for both production hosts. Pinned at the
    /// intermediate + root tier (not the leaf, which rotates far more
    /// often) so routine cert renewal doesn't require an SDK release:
    /// - GTS WR3 — the intermediate Google issues leaf certs from.
    /// - GTS Root R1 (RSA) / GTS Root R4 (ECDSA) — the two root CAs a
    ///   chain may present beneath that intermediate.
    private static let productionSPKIPins: Set<String> = [
        "OdSlmQD9NWJh4EbcOHBxkhygPwNSwA9Q91eounfbcoE=", // GTS WR3
        "hxqRlPTu1bMS/0DITB1SSu0vd4u/8l8TjPgfaAp63Gc=", // GTS Root R1 (RSA)
        "mEflZT5enoR1FuXLgYYGqnVEoZvmf9c2bVBpiOjYQ0c=", // GTS Root R4 (ECDSA)
    ]

    /// Pin set applied to both production hosts — `sessions.mollie.com` and
    /// `api.cc.mollie.com` sit behind the same Google Trust Services chain,
    /// so the same pins apply to each.
    private static let productionPins: [String: Set<String>] = [
        "sessions.mollie.com": productionSPKIPins,
        "api.cc.mollie.com": productionSPKIPins,
    ]

    /// Pin-set expiry / rotation checkpoint. Once this date passes,
    /// `PublicKeyPinner` stops enforcing `productionPins` and silently
    /// falls back to system trust only — a missed rotation degrades
    /// gracefully rather than bricking the app. Set ~2 years out from
    /// when this pin set was authored (2026-07-07); before it arrives, the
    /// pins must be reverified (or rotated) per
    /// docs/security/tls-pin-rotation-runbook.md.
    private static let productionPinExpiry: Date = {
        var components = DateComponents()
        components.year = 2028
        components.month = 7
        components.day = 7
        components.timeZone = TimeZone(identifier: "UTC")
        return Calendar(identifier: .gregorian).date(from: components)! // swiftlint:disable:this force_unwrapping
    }()

    /// Builds the URLSession configuration used by `.production`.
    ///
    /// `URLSession.shared` ships untuned defaults (60s per request, a 7-day
    /// resource timeout, no connectivity waiting) that are wrong for a payment
    /// sheet the buyer is staring at. The values below trade those for:
    ///
    /// - `timeoutIntervalForRequest = 30`: a single request (e.g. tokenise,
    ///   poll) that goes quiet for 30s surfaces to the buyer rather than
    ///   spinning out to the 60s default.
    /// - `timeoutIntervalForResource = 120`: a hard ceiling on the whole
    ///   transfer. Paired with `waitsForConnectivity` so a stalled connection
    ///   can't keep the sheet spinning indefinitely — 120s is the absolute
    ///   cap before the attempt fails.
    /// - `waitsForConnectivity = true`: a brief connectivity blip waits (up to
    ///   the resource cap) for the network to come back instead of failing
    ///   instantly. Bounded by the 120s resource timeout above.
    private static func tunedProductionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 120
        configuration.waitsForConnectivity = true
        return configuration
    }
}
