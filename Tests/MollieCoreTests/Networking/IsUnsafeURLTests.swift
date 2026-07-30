import XCTest
@testable import MollieCore

/// Lexical-only URL safety tests for the 3DS WebView navigation policy.
/// `isUnsafeNavigation` must NOT resolve DNS — every assertion here is
/// against a string-shaped URL. Exercises scheme allowlist, hostname
/// rejection (`localhost`), IPv4 private/loopback/link-local/metadata
/// ranges, and IPv6 loopback/ULA/link-local/mapped-v4.
final class IsUnsafeURLTests: XCTestCase {
    // MARK: - Positive cases (must return true)

    func test_isUnsafe_httpScheme_returnsTrue() throws {
        try assertUnsafe("http://example.com")
    }

    func test_isUnsafe_javascriptScheme_returnsTrue() throws {
        try assertUnsafe("javascript:alert(1)")
    }

    func test_isUnsafe_fileScheme_returnsTrue() throws {
        // file: can read the local filesystem — NOT a hostless-benign
        // content scheme. Stays blocked.
        try assertUnsafe("file:///etc/passwd")
    }

    func test_isUnsafe_mailtoScheme_returnsTrue() throws {
        try assertUnsafe("mailto:a@b.com")
    }

    func test_isUnsafe_telScheme_returnsTrue() throws {
        try assertUnsafe("tel:1234")
    }

    func test_isUnsafe_ipv4Loopback_returnsTrue() throws {
        try assertUnsafe("https://127.0.0.1/x")
    }

    func test_isUnsafe_localhostHostname_returnsTrue() throws {
        try assertUnsafe("https://localhost/x")
    }

    func test_isUnsafe_localhostHostnameMixedCase_returnsTrue() throws {
        try assertUnsafe("https://LocalHost/x")
    }

    func test_isUnsafe_ipv4Rfc1918_10dot_returnsTrue() throws {
        try assertUnsafe("https://10.0.0.1/x")
    }

    func test_isUnsafe_ipv4Rfc1918_192dot168_returnsTrue() throws {
        try assertUnsafe("https://192.168.1.1/x")
    }

    func test_isUnsafe_ipv4Rfc1918_172dot16_returnsTrue() throws {
        try assertUnsafe("https://172.16.0.1/x")
    }

    func test_isUnsafe_ipv4Rfc1918_172dot31_returnsTrue() throws {
        try assertUnsafe("https://172.31.255.255/x")
    }

    func test_isUnsafe_ipv4LinkLocalAwsMetadata_returnsTrue() throws {
        // 169.254.169.254 — AWS / GCP / Azure instance metadata endpoint.
        // Critical to block: a malicious ACS redirect here could exfil
        // cloud creds if this code ever ran inside a VM proxy.
        try assertUnsafe("https://169.254.169.254/x")
    }

    func test_isUnsafe_ipv6Loopback_returnsTrue() throws {
        try assertUnsafe("https://[::1]/x")
    }

    func test_isUnsafe_ipv6LinkLocal_returnsTrue() throws {
        try assertUnsafe("https://[fe80::1]/x")
    }

    func test_isUnsafe_ipv6UniqueLocal_returnsTrue() throws {
        try assertUnsafe("https://[fc00::1]/x")
    }

    func test_isUnsafe_ipv6UniqueLocalFdRange_returnsTrue() throws {
        // fd00::/8 is inside fc00::/7 — also ULA, also blocked.
        try assertUnsafe("https://[fd12::1]/x")
    }

    func test_isUnsafe_ipv6MappedIpv4Loopback_returnsTrue() throws {
        // ::ffff:127.0.0.1 → must be recognised as the mapped 127.0.0.1.
        try assertUnsafe("https://[::ffff:127.0.0.1]/x")
    }

    // MARK: - Additional private/reserved ranges

    func test_isUnsafe_ipv4CGNAT_100dot64_returnsTrue() throws {
        // 100.64.0.0/10 — carrier-grade NAT (RFC6598). Exfil here lands
        // on shared ISP infra.
        try assertUnsafe("https://100.64.0.1/x")
    }

    func test_isUnsafe_ipv4CGNAT_100dot127_returnsTrue() throws {
        // Upper boundary of 100.64.0.0/10.
        try assertUnsafe("https://100.127.255.254/x")
    }

    func test_isSafe_ipv4CGNATBoundary_100dot63_returnsFalse() throws {
        // One below 100.64.0.0/10 — outside the range, must remain safe.
        try assertSafe("https://100.63.255.255/x")
    }

    func test_isSafe_ipv4CGNATBoundary_100dot128_returnsFalse() throws {
        try assertSafe("https://100.128.0.0/x")
    }

    func test_isUnsafe_ipv4IETFProtocolAssignments_192dot0dot0_returnsTrue() throws {
        // 192.0.0.0/24 — IETF protocol assignments.
        try assertUnsafe("https://192.0.0.1/x")
    }

    func test_isUnsafe_ipv4Benchmarking_198dot18_returnsTrue() throws {
        // 198.18.0.0/15 — benchmarking (RFC2544).
        try assertUnsafe("https://198.18.0.1/x")
    }

    func test_isUnsafe_ipv4Benchmarking_198dot19_returnsTrue() throws {
        try assertUnsafe("https://198.19.255.254/x")
    }

    func test_isUnsafe_ipv4Multicast_224dot_returnsTrue() throws {
        // 224.0.0.0/4 — multicast.
        try assertUnsafe("https://224.0.0.1/x")
    }

    func test_isUnsafe_ipv4ReservedFuture_240dot_returnsTrue() throws {
        // 240.0.0.0/4 — reserved.
        try assertUnsafe("https://240.0.0.1/x")
    }

    func test_isUnsafe_ipv4LimitedBroadcast_returnsTrue() throws {
        // 255.255.255.255 — limited broadcast (inside 240.0.0.0/4).
        try assertUnsafe("https://255.255.255.255/x")
    }

    func test_isUnsafe_ipv4AzureMetadata_168dot63_returnsTrue() throws {
        // 168.63.129.16 — Azure instance metadata (not covered by 169.254/16).
        try assertUnsafe("https://168.63.129.16/x")
    }

    func test_isSafe_ipv4AzureMetadataAdjacent_returnsFalse() throws {
        // Adjacent address must NOT be over-blocked — only the exact
        // 168.63.129.16 is the Azure metadata endpoint.
        try assertSafe("https://168.63.129.17/x")
    }

    func test_isUnsafe_ipv4ZeroBlock_0dot1_returnsTrue() throws {
        // 0.0.0.0/8 — "this network", non-routable.
        try assertUnsafe("https://0.1.2.3/x")
    }

    func test_isUnsafe_ipv6Multicast_ff00_returnsTrue() throws {
        // ff00::/8 — multicast.
        try assertUnsafe("https://[ff00::1]/x")
    }

    func test_isUnsafe_ipv6Multicast_ff02_returnsTrue() throws {
        // ff02::1 — all-nodes link-local multicast.
        try assertUnsafe("https://[ff02::1]/x")
    }

    func test_isUnsafe_ipv6NAT64WithLoopback_returnsTrue() throws {
        // 64:ff9b::127.0.0.1 — NAT64 wraps a loopback v4 → must inherit
        // its verdict and be blocked.
        try assertUnsafe("https://[64:ff9b::7f00:1]/x")
    }

    func test_isUnsafe_ipv6Documentation_2001db8_returnsTrue() throws {
        // 2001:db8::/32 — documentation prefix.
        try assertUnsafe("https://[2001:db8::1]/x")
    }

    func test_isUnsafe_ipv6Unspecified_returnsTrue() throws {
        // :: — unspecified.
        try assertUnsafe("https://[::]/x")
    }

    // MARK: - Negative cases (must return false)

    func test_isSafe_httpsPublicHost_returnsFalse() throws {
        try assertSafe("https://example.com")
    }

    // MARK: - Hostless local content schemes (must return false)

    //
    // about:/data:/blob: have no network host, so they can neither
    // downgrade to http nor reach a private/loopback/metadata address —
    // this guard (which gates *navigations*, not fetch/XHR) does not apply.
    // Real 3DS ACS pages load these in helper iframes (observed: the Arcot
    // ACS navigates `about:` subframes during a live challenge). Blocking
    // them aborts legitimate challenges for zero security benefit, since the
    // content runs in an opaque origin with no access to the session.

    func test_isSafe_aboutBlank_returnsFalse() throws {
        try assertSafe("about:blank")
    }

    func test_isSafe_aboutSrcdoc_returnsFalse() throws {
        // about:srcdoc — the URL of an <iframe srcdoc="…"> document.
        try assertSafe("about:srcdoc")
    }

    func test_isSafe_dataScheme_returnsFalse() throws {
        try assertSafe("data:text/html,<h1>x</h1>")
    }

    func test_isSafe_blobScheme_returnsFalse() throws {
        try assertSafe("blob:https://acs.bank.com/550e8400-e29b-41d4-a716-446655440000")
    }

    func test_isSafe_httpsAcsHost_returnsFalse() throws {
        try assertSafe("https://acs.bank.com")
    }

    func test_isSafe_ipv4JustOutsideRfc1918_172dot15_returnsFalse() throws {
        // 172.15.255.255 is one address below the start of 172.16.0.0/12.
        try assertSafe("https://172.15.255.255/x")
    }

    func test_isSafe_ipv4JustOutsideRfc1918_172dot32_returnsFalse() throws {
        try assertSafe("https://172.32.0.0/x")
    }

    func test_isSafe_ipv4JustOutsideRfc1918_11dot_returnsFalse() throws {
        try assertSafe("https://11.0.0.1/x")
    }

    func test_isSafe_ipv4JustOutsideRfc1918_193dot168_returnsFalse() throws {
        try assertSafe("https://193.168.1.1/x")
    }

    // MARK: - Known gaps

    func test_isUnsafe_ipv4DecimalEncodedLoopback_returnsTrue() throws {
        // KNOWN GAP: `IPv4Address` from the Network framework only accepts
        // `IPv4Address("2130706433")` from the Network framework *does*
        // parse decimal-encoded IP literals (decimal-encoded 127.0.0.1)
        // — better than the original "known gap" assumption. The
        // function correctly rejects it as unsafe. If a future Network
        // framework version stops accepting this form, this test will
        // flip and the lexical check will need to be hardened with an
        // explicit `in_addr_t` parse before the IPv4Address fallback.
        let url = try XCTUnwrap(URL(string: "https://2130706433/x"))
        XCTAssertTrue(isUnsafeNavigation(url: url))
    }

    // MARK: - Helpers

    private func assertUnsafe(_ urlString: String, file: StaticString = #file, line: UInt = #line) throws {
        let url = try XCTUnwrap(URL(string: urlString), file: file, line: line)
        XCTAssertTrue(isUnsafeNavigation(url: url), "Expected \(urlString) to be unsafe", file: file, line: line)
    }

    private func assertSafe(_ urlString: String, file: StaticString = #file, line: UInt = #line) throws {
        let url = try XCTUnwrap(URL(string: urlString), file: file, line: line)
        XCTAssertFalse(isUnsafeNavigation(url: url), "Expected \(urlString) to be safe", file: file, line: line)
    }
}
