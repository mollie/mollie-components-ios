import CryptoKit
import Foundation
import Security

/// Additive SPKI public-key pinning on top of system TLS trust evaluation.
///
/// `evaluate(serverTrust:host:)` first runs the platform's own trust
/// evaluation (`SecTrustEvaluateWithError`) — pinning never rescues a chain
/// system trust has already rejected, so a failure there returns `false`
/// immediately. Only once system trust passes does pinning add its own,
/// stricter check for hosts it knows about: at least one certificate in the
/// presented chain must carry an SPKI-SHA256 hash from that host's pinned
/// set, otherwise the connection is rejected (fail closed). Once the pin
/// set's `expiry` has passed, pinning silently degrades to
/// system-trust-only for every host — a missed pin rotation must never
/// brick the app.
///
/// Value-semantic and thread-safe by construction: every stored property is
/// an immutable `let`, so a single instance can be shared and evaluated
/// concurrently without synchronization.
package struct PublicKeyPinner {
    /// Base64 SPKI-SHA256 hashes, keyed by pinned host.
    package let pins: [String: Set<String>]

    /// Once `now()` reaches this date, `evaluate` no longer enforces pins
    /// for any host and falls back to the system trust result.
    package let expiry: Date

    /// Injected clock so expiry behaviour is deterministic in tests.
    package let now: () -> Date

    package init(pins: [String: Set<String>], expiry: Date, now: @escaping () -> Date = Date.init) {
        self.pins = pins
        self.expiry = expiry
        self.now = now
    }

    /// Evaluates `serverTrust` for `host`, additively strengthening system
    /// trust with an SPKI pin check. See the type documentation for the
    /// three-step algorithm.
    package func evaluate(serverTrust: SecTrust, host: String) -> Bool {
        var error: CFError?
        guard SecTrustEvaluateWithError(serverTrust, &error) else {
            // Pinning never rescues a chain system trust already rejected.
            MollieLogger.log(
                "PublicKeyPinner",
                "system-trust-failed host=\(host) reason=\(error.map { ($0 as Error).localizedDescription } ?? "unknown")"
            )
            return false
        }

        guard let pinnedHashes = pins[host], now() < expiry else {
            // Unpinned host or expired pin set: system trust passed above,
            // so accept on that basis alone.
            return true
        }

        let presentedHashes = Self.spkiHashes(in: serverTrust)
        return !pinnedHashes.isDisjoint(with: presentedHashes)
    }

    /// SPKI-SHA256 hashes for every certificate in the presented chain.
    static func spkiHashes(in serverTrust: SecTrust) -> Set<String> {
        guard let chain = SecTrustCopyCertificateChain(serverTrust) as? [SecCertificate] else {
            return []
        }
        return Set(chain.compactMap(spkiHash(for:)))
    }

    /// SHA-256 of a certificate's DER-encoded SubjectPublicKeyInfo, base64
    /// encoded (the RFC 7469 SPKI pin format).
    static func spkiHash(for certificate: SecCertificate) -> String? {
        guard let publicKey = SecCertificateCopyKey(certificate) else { return nil }
        return spkiHash(for: publicKey)
    }

    /// `SecKeyCopyExternalRepresentation` returns only the raw key payload
    /// (PKCS#1 for RSA, the X9.63 point for EC) — not the full SPKI
    /// structure. The algorithm- and size-specific DER header is prepended
    /// to reconstruct it before hashing.
    private static func spkiHash(for publicKey: SecKey) -> String? {
        guard
            let attributes = SecKeyCopyAttributes(publicKey) as? [CFString: Any],
            let keyType = attributes[kSecAttrKeyType] as? String,
            let keySizeInBits = attributes[kSecAttrKeySizeInBits] as? Int,
            let header = spkiHeader(keyType: keyType, keySizeInBits: keySizeInBits),
            let rawKeyData = SecKeyCopyExternalRepresentation(publicKey, nil) as Data?
        else {
            return nil
        }

        let digest = SHA256.hash(data: header + rawKeyData)
        return Data(digest).base64EncodedString()
    }

    /// The DER `AlgorithmIdentifier` + `BIT STRING` prefix that, prepended
    /// to the raw key data, reconstructs the full DER SubjectPublicKeyInfo.
    /// Depends on both the algorithm and key size, since the BIT STRING
    /// length field differs per size. Covers the RSA and EC sizes used by
    /// the pinned CA chain; an unrecognized combination yields no hash for
    /// that certificate rather than a guess.
    private static func spkiHeader(keyType: String, keySizeInBits: Int) -> Data? {
        let rsaKeyType = kSecAttrKeyTypeRSA as String
        let ecKeyType = kSecAttrKeyTypeECSECPrimeRandom as String

        switch (keyType, keySizeInBits) {
        case (rsaKeyType, 2048):
            return Data([
                0x30, 0x82, 0x01, 0x22, 0x30, 0x0D, 0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01,
                0x01, 0x05, 0x00, 0x03, 0x82, 0x01, 0x0F, 0x00,
            ])
        case (rsaKeyType, 4096):
            return Data([
                0x30, 0x82, 0x02, 0x22, 0x30, 0x0D, 0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01,
                0x01, 0x05, 0x00, 0x03, 0x82, 0x02, 0x0F, 0x00,
            ])
        case (ecKeyType, 256):
            return Data([
                0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01, 0x06, 0x08, 0x2A,
                0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07, 0x03, 0x42, 0x00,
            ])
        case (ecKeyType, 384):
            return Data([
                0x30, 0x76, 0x30, 0x10, 0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01, 0x06, 0x05, 0x2B,
                0x81, 0x04, 0x00, 0x22, 0x03, 0x62, 0x00,
            ])
        default:
            return nil
        }
    }
}

/// Bridges the pure `PublicKeyPinner.evaluate` core to `URLSessionDelegate`
/// server-trust authentication challenges.
///
/// `URLSessionDelegate` requires a reference type, so this thin `NSObject`
/// subclass owns a `PublicKeyPinner` value and forwards each server-trust
/// challenge to it, resolving the challenge to `.useCredential` or
/// `.cancelAuthenticationChallenge`. Any other authentication method is left
/// to the platform's default handling; a server-trust challenge with no trust
/// object attached is rejected outright (fail closed).
package final class PinningURLSessionDelegate: NSObject, URLSessionDelegate {
    private let pinner: PublicKeyPinner

    package init(pinner: PublicKeyPinner) {
        self.pinner = pinner
    }

    package func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let protectionSpace = challenge.protectionSpace
        let (disposition, credential) = decide(
            authenticationMethod: protectionSpace.authenticationMethod,
            serverTrust: protectionSpace.serverTrust,
            host: protectionSpace.host
        )
        completionHandler(disposition, credential)
    }

    /// The decision behind `urlSession(_:didReceive:completionHandler:)`,
    /// factored out of `URLAuthenticationChallenge`/`URLProtectionSpace` so
    /// it can be exercised directly in tests: neither type has a public
    /// initializer (nor a KVC-settable property) for attaching a `SecTrust`
    /// to a protection space outside of a live TLS handshake, since the OS
    /// is normally the only one that ever populates it.
    func decide(
        authenticationMethod: String,
        serverTrust: SecTrust?,
        host: String
    ) -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard authenticationMethod == NSURLAuthenticationMethodServerTrust else {
            // Not a server-trust challenge — pinning has no opinion; leave
            // other auth methods to the platform.
            return (.performDefaultHandling, nil)
        }
        guard let serverTrust else {
            // A server-trust challenge with no trust object is anomalous (the
            // OS always populates it during a live handshake). Reject
            // explicitly rather than deferring — the pinning path fails closed.
            return (.cancelAuthenticationChallenge, nil)
        }

        let trusted = pinner.evaluate(serverTrust: serverTrust, host: host)
        MollieLogger.log("PublicKeyPinner", "host=\(host) trusted=\(trusted)")

        return trusted
            ? (.useCredential, URLCredential(trust: serverTrust))
            : (.cancelAuthenticationChallenge, nil)
    }
}
