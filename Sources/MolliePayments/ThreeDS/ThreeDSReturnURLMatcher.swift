import Foundation

package struct ThreeDSReturnURLMatcher {
    /// Production allow-list — only the canonical Mollie 3DS return host. Any
    /// other host (including `api.mollie.com`, which used to live here for
    /// test-fixture reasons) is rejected. Tests that need to drive fixtures
    /// against another host construct the matcher via `init(testFixtureHosts:)`
    /// (test-only).
    private static let productionHosts: Set<String> = [
        "secure-3ds.mollie.com",
    ]

    private let allowedHosts: Set<String>

    package init() {
        allowedHosts = Self.productionHosts
    }

    #if DEBUG
        /// SPI seam for tests that exercise legacy fixtures on hosts not in the
        /// production allow-list (e.g. `api.mollie.com`). Symbol is compiled out
        /// of Release builds — production merchant code cannot weaken the
        /// allow-list.
        package init(testFixtureHosts: Set<String>) {
            allowedHosts = Self.productionHosts.union(testFixtureHosts)
        }
    #endif

    package func matches(_ url: URL) -> Bool {
        guard url.scheme == "https" else { return false }
        guard let host = url.host?.lowercased(), allowedHosts.contains(host) else { return false }
        // Exact match or a strict child segment — `…/3ds/return-fake` and
        // `…/3ds/returnFOO` must NOT match, but `…/3ds/return` and
        // `…/3ds/return/xyz` must.
        return url.path == "/3ds/return" || url.path.hasPrefix("/3ds/return/")
    }

    package func parseResult(from url: URL) -> ThreeDSResult {
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let status = comps?.queryItems?.first(where: { $0.name == "status" })?.value
        switch status {
        case "authenticated": return .authenticated
        case "failed":
            let reason = comps?.queryItems?.first(where: { $0.name == "reason" })?.value
            return .failed(reason: reason.map { .sdkError(message: $0) } ?? .challengeFailed)
        case nil:
            // No status query parameter — user navigated away without completing.
            return .cancelled
        default:
            // Status present but unrecognised — server returned something the SDK
            // doesn't understand. Treat as a failure rather than masking it as a cancel.
            return .failed(reason: .sdkError(message: "Unknown 3DS return status: \(status ?? "nil")"))
        }
    }
}
