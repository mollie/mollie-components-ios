import Foundation
import Network

/// Returns `true` for any URL the 3DS WebView must refuse to navigate to.
///
/// Rules:
/// - `https` is allowed (subject to the host checks below).
/// - `about` / `data` / `blob` are allowed: hostless local content schemes
///   with no network destination (real 3DS ACS pages load `about:blank` /
///   `about:srcdoc` / `data:` helper iframes). They can neither downgrade to
///   http nor reach a private/metadata IP, so this navigation guard does not
///   apply to them.
/// - Every other scheme (http, file, javascript, mailto, tel, custom schemes)
///   is rejected.
/// - Hostnames `localhost` (any case) and IPv4/IPv6 addresses inside private,
///   loopback, link-local, ULA, multicast, reserved, cloud-metadata, CGNAT,
///   benchmarking, IETF assignment, or NAT64 ranges are rejected.
/// - Purely lexical — no DNS resolution (resolution is TOCTOU-vulnerable).
///
/// Lives in `MollieCore` (outside `ThreeDSWebViewController` and the
/// UIKit/WebKit `#if`) so it can be unit-tested on macOS where `UIKit` is
/// unavailable AND shared by both the 3DS WebView navigation gate and the
/// session→event mapper (`SessionEventMapper`), which validates challenge /
/// redirect URLs before they ever reach a presented sheet.
package func isUnsafeNavigation(url: URL) -> Bool {
    let scheme = url.scheme?.lowercased()
    // Hostless local content schemes carry no network destination: they can
    // neither downgrade to http nor reach a private/loopback/metadata IP, so
    // this guard — which gates frame *navigations*, not fetch/XHR — does not
    // apply. Real 3DS ACS challenge pages load `about:blank` / `about:srcdoc`
    // (helper + srcdoc iframes), `data:`, and `blob:` documents in subframes;
    // blocking them aborts legitimate challenges for no security benefit (the
    // content runs in an opaque origin with no access to the session).
    // `file:` (local-filesystem read) and `javascript:` (executes in the page
    // origin) are deliberately NOT in this set — they fall through and are
    // rejected by the https-only guard below.
    if scheme == "about" || scheme == "data" || scheme == "blob" {
        return false
    }
    guard scheme == "https" else { return true }
    guard let rawHost = url.host, !rawHost.isEmpty else { return false }
    let host = rawHost.lowercased()

    if host == "localhost" {
        return true
    }

    let bare = host.hasPrefix("[") && host.hasSuffix("]")
        ? String(host.dropFirst().dropLast())
        : host

    if let ipv4 = IPv4Address(bare) {
        return isUnsafeIPv4(ipv4)
    }
    if let ipv6 = IPv6Address(bare) {
        return isUnsafeIPv6(ipv6)
    }
    return false
}

// swiftlint:disable:next cyclomatic_complexity
private func isUnsafeIPv4(_ addr: IPv4Address) -> Bool {
    let bytes = addr.rawValue
    guard bytes.count == 4 else { return false }
    let first = bytes[0]
    let second = bytes[1]
    // 0.0.0.0/8 — "this network", unspecified. Catch the canonical 0.0.0.0
    // as well as any 0.x.y.z literal which is non-routable.
    if first == 0 {
        return true
    }
    // 127.0.0.0/8 — loopback.
    if first == 127 {
        return true
    }
    // 10.0.0.0/8 — RFC1918 private.
    if first == 10 {
        return true
    }
    // 172.16.0.0/12 — RFC1918 private.
    if first == 172, (16 ... 31).contains(second) {
        return true
    }
    // 192.168.0.0/16 — RFC1918 private.
    if first == 192, second == 168 {
        return true
    }
    // 169.254.0.0/16 — link-local + cloud-instance metadata (AWS/GCP/Azure
    // expose creds at 169.254.169.254).
    if first == 169, second == 254 {
        return true
    }
    // 100.64.0.0/10 — CGNAT. ISP-side carrier-grade NAT range; an exfil to
    // here can land on shared-tenancy infra.
    if first == 100, (64 ... 127).contains(second) {
        return true
    }
    // 192.0.0.0/24 — IETF protocol assignments. Reserved for IANA.
    if first == 192, second == 0, bytes[2] == 0 {
        return true
    }
    // 198.18.0.0/15 — benchmarking (RFC2544).
    if first == 198, (18 ... 19).contains(second) {
        return true
    }
    // 224.0.0.0/4 — multicast.
    if (224 ... 239).contains(first) {
        return true
    }
    // 240.0.0.0/4 — reserved for future use. Includes 255.255.255.255
    // limited broadcast.
    if first >= 240 {
        return true
    }
    // Azure instance metadata (the canonical 168.63.129.16 endpoint). Not
    // covered by 169.254/16 because Azure picked a public-looking address.
    if first == 168, second == 63, bytes[2] == 129, bytes[3] == 16 {
        return true
    }
    return false
}

// swiftlint:disable:next cyclomatic_complexity
private func isUnsafeIPv6(_ addr: IPv6Address) -> Bool {
    let bytes = addr.rawValue
    guard bytes.count == 16 else { return false }
    // ::/128 — unspecified address. All-zero literal.
    if bytes.allSatisfy({ $0 == 0 }) {
        return true
    }
    // ::1/128 — loopback.
    if bytes.prefix(15).allSatisfy({ $0 == 0 }), bytes[15] == 1 {
        return true
    }
    // fc00::/7 — Unique Local Addresses (ULA, RFC4193). Matches fc00::/8 and
    // fd00::/8.
    if (bytes[0] & 0xFE) == 0xFC {
        return true
    }
    // fe80::/10 — link-local.
    if bytes[0] == 0xFE, (bytes[1] & 0xC0) == 0x80 {
        return true
    }
    // ff00::/8 — multicast.
    if bytes[0] == 0xFF {
        return true
    }
    // 2001:db8::/32 — documentation prefix (RFC3849). Must never appear in
    // real traffic; if seen, the URL came from a doc/sample → reject.
    if bytes[0] == 0x20, bytes[1] == 0x01, bytes[2] == 0x0D, bytes[3] == 0xB8 {
        return true
    }
    // 64:ff9b::/96 — well-known NAT64 prefix (RFC6052). Embeds an IPv4 in
    // the last 32 bits; if that v4 is itself unsafe, the v6 form is too.
    // swiftlint:disable opening_brace
    if bytes[0] == 0x00, bytes[1] == 0x64, bytes[2] == 0xFF, bytes[3] == 0x9B,
       bytes.dropFirst(4).prefix(8).allSatisfy({ $0 == 0 })
    {
        let mapped = IPv4Address(Data(bytes.suffix(4)))
        if let mapped {
            return isUnsafeIPv4(mapped)
        }
        return true
    }
    // swiftlint:enable opening_brace
    // ::ffff:0:0/96 — IPv4-mapped IPv6. ::ffff:127.0.0.1 must inherit v4's
    // verdict so a v6 literal can't bypass the v4 private-range check.
    if bytes.prefix(10).allSatisfy({ $0 == 0 }), bytes[10] == 0xFF, bytes[11] == 0xFF {
        let mapped = IPv4Address(Data(bytes.suffix(4)))
        if let mapped {
            return isUnsafeIPv4(mapped)
        }
    }
    return false
}
