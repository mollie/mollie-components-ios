import Foundation

/// Override the Mollie service endpoints the payment sheet routes through.
///
/// Default values point at the production hosts — `sessions.mollie.com`
/// and `api.cc.mollie.com`. Merchants integrating against production
/// don't need to construct this type; the standard
/// `MolliePaymentSheet.present(from:clientToken:theme:)` overload uses
/// the defaults automatically.
///
/// **When you DO need this:** to point the sheet at a non-production Mollie
/// host — for example a test/sandbox environment or a local development server.
///
/// **What `testmode` does instead:** the `testmode` bit on the decoded
/// `clientToken` already routes test-vs-live payment processing on the
/// production hosts. You do NOT need `MolliePaymentEndpoints` to test
/// card payments against production Mollie — pass a test-mode
/// `clientToken` and you're done.
public struct MolliePaymentEndpoints: @unchecked Sendable {
    /// Base URL of the Sessions Service the sheet talks to for session
    /// state and polling. Defaults to the production host in `.production`.
    public let sessionsBaseURL: URL
    /// Base URL of the PCI card tokeniser the sheet posts card data to in
    /// exchange for a single-use token. Defaults to the production host in
    /// `.production`.
    public let tokenizerBaseURL: URL

    /// URLSession used by the sheet's HTTP clients. `.production` uses a
    /// tuned session (bounded request/resource timeouts + connectivity
    /// waiting — see `tunedProductionConfiguration()`); callers targeting a
    /// non-production host can pass a session configured to trust that host
    /// (e.g. one backed by a delegate that accepts a development server's
    /// self-signed cert).
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
    public static let production = MolliePaymentEndpoints(
        sessionsBaseURL: URL(string: "https://sessions.mollie.com")!, // swiftlint:disable:this force_unwrapping
        tokenizerBaseURL: URL(string: "https://api.cc.mollie.com")!, // swiftlint:disable:this force_unwrapping
        urlSession: URLSession(configuration: tunedProductionConfiguration())
    )

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
