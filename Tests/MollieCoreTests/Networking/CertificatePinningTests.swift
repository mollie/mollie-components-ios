import Security
import XCTest
@testable import MollieCore

final class CertificatePinningTests: XCTestCase {
    // MARK: - Fixture certificate

    //
    // A self-signed RSA-2048 leaf (also used as its own trust anchor),
    // generated once via:
    //   openssl req -x509 -newkey rsa:2048 -keyout key.pem -out cert.pem \
    //     -days 365 -nodes -sha256 -config ext.cnf
    // (ext.cnf: CN=pinning-test.example, basicConstraints=CA:true,
    //  subjectAltName=DNS:pinning-test.example — a SAN is required for
    //  SecTrustEvaluateWithError to accept the leaf on current OS versions.
    //  The validity period must stay within Apple's maximum TLS leaf
    //  lifetime (398 days) or SecTrustEvaluateWithError rejects the chain
    //  with "exceeds maximum temporal validity period" regardless of the
    //  anchor being trusted.)
    // No key material or openssl artifacts are committed — only the
    // resulting certificate DER (base64) below.
    private static let fixtureHost = "pinning-test.example"

    private static let fixtureCertificateBase64 = "MIIDRDCCAiygAwIBAgIUXEVcz+3YEk/6wFWuAogM/W5GnmAwDQYJKoZIhvcNAQELBQAwHzEdMBsGA1UEAwwUcGlubmluZy10ZXN0LmV4YW1wbGUwHhcNMjYwNzA3MDgxNjE5WhcNMjcwNzA3MDgxNjE5WjAfMR0wGwYDVQQDDBRwaW5uaW5nLXRlc3QuZXhhbXBsZTCCASIwDQYJKoZIhvcNAQEBBQADggEPADCCAQoCggEBAJcbry3xt1BBo/cwCQ9F18Y1gtrNOef2FHlDI0tnl3/2PZhJUZ9mNdFhNYG/0A0Lk97CmScu4+6MRyEp4h9FGg8WrfyaXttKHyR64kMF9E47YOhykETB46e+hSLRbyrUkHzDdZFMwkDHDlLPopFKQpOsNREOUkBNsst1Ka09KH/WFiZRKji1J0+Ny3+turUpxhfbvRvsasb0IIAU/RqNSnkSd+IqsyBdppl7+7BiwNySYwKWlpseOHf56OBhFJveN04Ie8pY4/Rc7U+pVImoEPUSPJhJ4nANiyVMjFxdhLzQzMZxzDSSlL236Ljp0T/Ir91eofOIbim+AT13VqyaC/ECAwEAAaN4MHYwDwYDVR0TAQH/BAUwAwEB/zAOBgNVHQ8BAf8EBAMCAoQwEwYDVR0lBAwwCgYIKwYBBQUHAwEwHwYDVR0RBBgwFoIUcGlubmluZy10ZXN0LmV4YW1wbGUwHQYDVR0OBBYEFHSe/JMRewwzZVJnYSOhnPga5NuMMA0GCSqGSIb3DQEBCwUAA4IBAQAPCzKPAoDdC8mpnbm3jqRD/sUooCrEBm0W3v0e7AAeYsp5uI7iLPKGCvhZUSwnhYgUzJXWJDMGeJklZqBkToo2QLjbxVn8UyJrZ5oku6KYgTw09CLV991brBSv08P91fa9P3cPZcdrH2qOUPBfnbck5Dx9L7ZjfEXQak8h4cQMxiRTIUupgJE9JWfaMWtD8pE2x9jEwWuIU8UpK3YtqHvNxrGAYeuCgaiGJVxild1tNmm7Qd/WypCy70F7MTDieh8iIDMmQwf6kusUx3aI1Z5OgkDTA9wIBpsgn5sSuRR2P1Ul7Im10OQ744Ye+1dlHyvnS72v9ZqCZVkwV7RUDi+/"

    /// The SPKI-SHA256 pin for the fixture's public key, computed the same
    /// way production pins are derived:
    ///   openssl x509 -in cert.pem -pubkey -noout \
    ///     | openssl pkey -pubin -outform der \
    ///     | openssl dgst -sha256 -binary | base64
    private static let fixtureCorrectPin = "K+1/7uOnuOktxZy9QAjAexLENRaHvGAdTWhetu7eoKU="

    /// An unrelated SHA-256/base64 value with no relation to the fixture key
    /// — used to exercise the mismatch path.
    private static let wrongPin = "tZlGRKkESGi9NDju0Xo8VVGvexAtSyG+i0l3vxGwmFo="

    private func makeCertificate(base64: String) throws -> SecCertificate {
        let data = try XCTUnwrap(Data(base64Encoded: base64))
        return try XCTUnwrap(SecCertificateCreateWithData(nil, data as CFData))
    }

    private func makeFixtureCertificate() throws -> SecCertificate {
        try makeCertificate(base64: Self.fixtureCertificateBase64)
    }

    // MARK: - Fixture certificates: RSA-4096 and EC P-384 (production root key types)

    //
    // The production pinned chain includes GTS Root R1 (RSA-4096) and GTS
    // Root R4 (EC P-384) — key types the RSA-2048 fixture above doesn't
    // exercise in `spkiHeader(keyType:keySizeInBits:)`. These two fixtures
    // are self-signed certs of those exact key types/sizes, used only to
    // drive `PublicKeyPinner.spkiHash(for:)` directly (no SecTrust/system
    // evaluation involved), so they don't need a SAN or a short validity
    // period the way the trust-evaluation fixture above does.
    //
    // Generated once via, e.g. for RSA-4096:
    //   openssl req -x509 -newkey rsa:4096 -keyout key.pem -out cert.pem \
    //     -days 365 -nodes -sha256 -subj "/CN=pinning-test-rsa4096.example"
    // and for EC P-384:
    //   openssl ecparam -name secp384r1 -genkey -noout -out key.pem
    //   openssl req -x509 -new -key key.pem -out cert.pem \
    //     -days 365 -sha256 -subj "/CN=pinning-test-ec384.example"
    // No key material or openssl artifacts are committed — only the
    // resulting certificate DER (base64) and the openssl-computed expected
    // pin (same derivation as `fixtureCorrectPin` above) below.

    private static let fixtureCertificateRSA4096Base64 = "MIIFLzCCAxegAwIBAgIUWdtZEvWKS+knv2q4Ebcx54eRkWcwDQYJKoZIhvcNAQELBQAwJzElMCMGA1UEAwwccGlubmluZy10ZXN0LXJzYTQwOTYuZXhhbXBsZTAeFw0yNjA3MDcwODU1MTJaFw0yNzA3MDcwODU1MTJaMCcxJTAjBgNVBAMMHHBpbm5pbmctdGVzdC1yc2E0MDk2LmV4YW1wbGUwggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQDjvQ8lq55wo5IhpjOa1uwe0S38VzkciLpeY2Tikso2igY6WJofE2/pYv2dEKyOsfAJ8fOY/Hflvz4Mwcuc9Gv5cl8nBsUyrMNcnmUGC2lW9ZXSoF3b5QFfj40q5cKFYZ679BNNKZPoNX3J7kYuOFWWM9TvOMSNsXMAMpXbTnBaVg5TV48helNl4DC8/30J7HSts87TDjxuM4EowP0igcR08Ww+vVbfCz2URQseA99RjPKEZ83QIsioi2QaAargHdAPtIuoK9rAAt2Db45+t3uiL+Kvo/OzOtI0FqEO+lhacQKSzZy3XdvnD91CU0hnF685nXsOVKkFqTm1lRPJ/6C5YEq8DBU0iKMBbzd7/J4/3ZHbgOMsHyIT9GNf0ieFIPSLcvejVb0UtxhcOjJCk0N8meyBXPutlSPdQgJ2eUMIhifLui3Rapu1opUxxxW3nRCO8tuNpGvoCDh2FKLiGPSucsYbuPPiKUGqwxtrfqdCwKTEmYy6mS6mdYwVl4DBiTO644ewf50gPlfsWtHVcXcmLjTs8PcUIfvkuTz3I+f6cmCAqOVwHdhwW3So9zohNfxuIrHFD5Z2+F+4gi+H30c7lgc3IZhI0JTWOh9UiTNK6g26WbLYwSDiqIGyEZTKouPAmX3zrMWJ2eJxvBETpXyhrSpQw7E1mG2B0W/QEW8iFwIDAQABo1MwUTAdBgNVHQ4EFgQUijEdiBKNnLTv1FUWolAHH0yQ5gcwHwYDVR0jBBgwFoAUijEdiBKNnLTv1FUWolAHH0yQ5gcwDwYDVR0TAQH/BAUwAwEB/zANBgkqhkiG9w0BAQsFAAOCAgEAW62wvytR/K39fa/wEi0eIIKTJPIb7kPw+6qt8+aQ0Pg9T5oH44wkT70ZNlLOss3Ilj6PhMuvWk2rrScXLEsDcTLv13EoHJoAioGsObbBOPl7TgM84DVOcUUVj88RGwxTqGBsqgjIzx9XziNuQj8fJpolgNJdmwjtEC+JkSGI5DjdIIzNtA5DznuEZ6itUwPggzSf0vIpoERH8Yf+32i1Gd0CMlKJw/JX09Z5rC/Qnyypi/BerPVKXAJBo9c5j+HJdq5GVQAzoSos2vR7/Vp4Ie3dqnCDU4q2vvdO81IjPAqUemAdJkphveLQWGBmtnV0klon292rJLlQZEnsmpUhXPVXv7RdSBG3xLwtSLZfEvYbSGj56kGjojlBF8cQI3vE5hIAsBLkyFVkdV0EMglJsHwOkz3pH9IbP8ej4e7n0TVaJTRgvM3lvqKXRGrZknfVgvbWxXRLjuSjlAJg1SjlhEvt91GH3aZ5YSqkjFDBjXUHKKHMl5VVpyG2GL6plfYYykT2kg23Jw7r++VvXqDJ386HEENzb/sm+Yy0PWPABifdNKkvwkDqElus5TdZnSpvS58Hj6Msl+PWDQpjR1YE6+GFqSz6fMp0qmRXPu+1Rh3AjtJDNp4dO0x4IfuNGucNR5DitMwxc8fF8w8hczlIFfXmDyb+6Y6sn75W+175hes="

    private static let fixtureCorrectPinRSA4096 = "hX62t7EKhNSxkE8TjnsXcHkQ6SO532qAztP1iC8I4ec="

    private static let fixtureCertificateECP384Base64 = "MIIB3DCCAWKgAwIBAgIUC57mRDTZJWY+cDNKLg/U0kVJE1UwCgYIKoZIzj0EAwIwJTEjMCEGA1UEAwwacGlubmluZy10ZXN0LWVjMzg0LmV4YW1wbGUwHhcNMjYwNzA3MDg1NTEyWhcNMjcwNzA3MDg1NTEyWjAlMSMwIQYDVQQDDBpwaW5uaW5nLXRlc3QtZWMzODQuZXhhbXBsZTB2MBAGByqGSM49AgEGBSuBBAAiA2IABHpQsCAhhsGM+/ieLxWHU9doSQVC0s+RQGd6hIdWtm7INZY6ga+PvhYH2+ijqIFepfniwrKvfVqO6SyQlXShRyRvUxAa5zFZ0peiXsWd3ZfFKIFI6ykdG9vN7pp82pX+q6NTMFEwHQYDVR0OBBYEFJS/wSuk5M5G/gWPm3dSFxGEYQBKMB8GA1UdIwQYMBaAFJS/wSuk5M5G/gWPm3dSFxGEYQBKMA8GA1UdEwEB/wQFMAMBAf8wCgYIKoZIzj0EAwIDaAAwZQIwLaZrHSbARj4wNO7LCIx7ebD378gEGM9MUv35lOj76YahBXt2wdiSXtWCtFshn5bkAjEAxTpHNX9l8PgckTEF2aKOojgWqPopUS2Kv3L0ZN4pqYGh/L4fXxK+8cKlo+NdTrlm"

    private static let fixtureCorrectPinECP384 = "VgF0F0KCfLbrQ6T7TDGQVRfl8lNKoxpy16m6zk0lsxc="

    /// An EC P-256 self-signed cert. No production pin uses P-256 today, but the
    /// `(ecKeyType, 256)` branch in `spkiHeader` is live code that would silently
    /// produce a wrong hash (and reject valid connections) if that header ever
    /// regressed — e.g. if a GTS intermediate on a P-256 key were later pinned.
    /// Generated the same way as the P-384 fixture above (secp256r1 / prime256v1).
    private static let fixtureCertificateECP256Base64 = "MIIBnzCCAUWgAwIBAgIUcQjuJz/ILbBWn/3vrl8uLfav+30wCgYIKoZIzj0EAwIwJTEjMCEGA1UEAwwacGlubmluZy10ZXN0LWVjMjU2LmV4YW1wbGUwHhcNMjYwNzA5MTIyNTEzWhcNMjcwNzA5MTIyNTEzWjAlMSMwIQYDVQQDDBpwaW5uaW5nLXRlc3QtZWMyNTYuZXhhbXBsZTBZMBMGByqGSM49AgEGCCqGSM49AwEHA0IABAc5Mz5JjSJSnammeaes/00RM+9MS5yo7t6Y51IomdHTUc8SzXqOqlJ8Ncs4EndmMch/Ugz5Gu/Fj1bBPS59ToKjUzBRMB0GA1UdDgQWBBSYGcMExC4elDEgXe7zqQFCoUhdZDAfBgNVHSMEGDAWgBSYGcMExC4elDEgXe7zqQFCoUhdZDAPBgNVHRMBAf8EBTADAQH/MAoGCCqGSM49BAMCA0gAMEUCICIjLBzPwRN88W6QmFgFec/SgR/PnlqUSp9eKx66UFSQAiEAjVsvSEXuJ8jHiEDeTxRbWcKZf6OgZlbSV3NU5hXb/Jk="

    private static let fixtureCorrectPinECP256 = "cTAUWpKNK5SQ2k8ZuzGE9Ub5hcu4J77DfL6d79yFW+8="

    // MARK: - Fixture: unrelated anchor (fail-closed guard fallback only)

    ///
    /// A second, unrelated self-signed cert with no relation to `fixtureHost`'s
    /// key. Used only as a deterministic-failure fallback in the fail-closed
    /// guard test below, in the unlikely case the platform's trust store still
    /// accepts the un-anchored fixture certificate.
    private static let unrelatedAnchorCertificateBase64 = "MIIDJzCCAg+gAwIBAgIUZD3rtCU7f48bcubQVJkTD74dqHQwDQYJKoZIhvcNAQELBQAwIzEhMB8GA1UEAwwYdW5yZWxhdGVkLWFuY2hvci5leGFtcGxlMB4XDTI2MDcwNzA4NTUxMloXDTI3MDcwNzA4NTUxMlowIzEhMB8GA1UEAwwYdW5yZWxhdGVkLWFuY2hvci5leGFtcGxlMIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAmTjIcM+bqGHZl57+FBJV8DI3Q6Y+weqVMg2pR269ThZGyQH7C5DEmukfQ54Xo1EswvWtUI0OJuEe8RfgX3EeZAfBUVnwKZyElqW6KF7YQ17Z0xz2uQMsTJzyufo/VPMGvD9WKz4KvYLOUMm8KO5PtDatu33pVy2bMdEHGYk6uBOt9qv0mJB9Wuk/8T6rZqhIC9FK/jBCvosDEiM5vTCKUyI1o+sMv3nGnvzutxekE0tIwo9iHJuwUDjH7WMNdXE3/9lSEg/3/KoOQXJTUAISi5i5wS+uQJGJqla3JGbmNjOGL0quNnimj5O95kAhzKiRnBWLlNCnAxzHt7YqRVIMVQIDAQABo1MwUTAdBgNVHQ4EFgQUqJGA4bCQIla+R3OEYpvarJe23P0wHwYDVR0jBBgwFoAUqJGA4bCQIla+R3OEYpvarJe23P0wDwYDVR0TAQH/BAUwAwEB/zANBgkqhkiG9w0BAQsFAAOCAQEAJ0dMConPj5OWD+k4e7cHdiiipFfuzRatAdBQpZ6RI1jzmqzZyzzG8upnRbwWgzzvhpz2F4ptQDoIjX46vKboyPR/8OK8zJ/qatOE8LhSzydNNj6FlQQupZrNZJYVAxJ7bBQsJ3QXZs3IJ52ITuqaQF6p/S+m8IgC+HovDShOVwFBSNOTV3ghw/PWKEN/e2tCsdL3kw47YqgNtcrRz3HDfcowQAO7VGosw0Bv0OKdDSpQTzsxpLsShsbAwCDFtzZV4oRdf6Tfmf5v/x86pie4g9LlhCJXNOKrX0PpvvcjvQsjuvX7ScmMFZlWdm26x0HqieOFBUEf7jM2RTEM+5uQmA=="

    /// Builds a `SecTrust` for the fixture certificate, trusting it (and
    /// thus its self-signed issuer) as an anchor so `SecTrustEvaluateWithError`
    /// passes deterministically regardless of the host device's trust store.
    private func makeFixtureTrust() throws -> SecTrust {
        let certificate = try makeFixtureCertificate()
        var trust: SecTrust?
        let status = SecTrustCreateWithCertificates(
            certificate,
            SecPolicyCreateSSL(true, Self.fixtureHost as CFString),
            &trust
        )
        XCTAssertEqual(status, errSecSuccess)
        let secTrust = try XCTUnwrap(trust)
        SecTrustSetAnchorCertificates(secTrust, [certificate] as CFArray)
        // Trust only the explicit fixture anchor — SecTrustSetAnchorCertificates
        // appends to (rather than replaces) the platform root store, so without
        // this every scenario would also consult the device's live CAs. Locking
        // to the fixture makes evaluation fully environment-independent.
        SecTrustSetAnchorCertificatesOnly(secTrust, true)
        return secTrust
    }

    // MARK: - Scenario 1: unpinned host passes through system trust

    func test_evaluate_unpinnedHost_returnsSystemTrustResult() throws {
        let trust = try makeFixtureTrust()
        let pinner = PublicKeyPinner(
            pins: ["other.example": ["irrelevant-pin"]],
            expiry: Date.distantFuture,
            now: { Date.distantPast }
        )

        XCTAssertTrue(pinner.evaluate(serverTrust: trust, host: Self.fixtureHost))
    }

    // MARK: - Scenario 2: matching pin + valid system trust → true

    func test_evaluate_matchingPin_returnsTrue() throws {
        let trust = try makeFixtureTrust()
        let pinner = PublicKeyPinner(
            pins: [Self.fixtureHost: [Self.fixtureCorrectPin]],
            expiry: Date.distantFuture,
            now: { Date.distantPast }
        )

        XCTAssertTrue(pinner.evaluate(serverTrust: trust, host: Self.fixtureHost))
    }

    // MARK: - Scenario 3: mismatched pin → false (fail closed)

    func test_evaluate_mismatchedPin_returnsFalse() throws {
        let trust = try makeFixtureTrust()
        let pinner = PublicKeyPinner(
            pins: [Self.fixtureHost: [Self.wrongPin]],
            expiry: Date.distantFuture,
            now: { Date.distantPast }
        )

        XCTAssertFalse(pinner.evaluate(serverTrust: trust, host: Self.fixtureHost))
    }

    // MARK: - Scenario 4: expired pin set degrades to system-trust-only

    func test_evaluate_expiredPinSet_ignoresMismatchAndReturnsSystemTrustResult() throws {
        let trust = try makeFixtureTrust()
        let pinner = PublicKeyPinner(
            pins: [Self.fixtureHost: [Self.wrongPin]],
            expiry: Date.distantPast,
            now: { Date.distantFuture }
        )

        // The pin is wrong, but the pin set already expired — pinning must
        // not hard-fail on a missed rotation, so this degrades to the
        // (passing) system trust result.
        XCTAssertTrue(pinner.evaluate(serverTrust: trust, host: Self.fixtureHost))
    }

    // MARK: - Scenario 5: SPKI extraction correctness

    func test_spkiHash_matchesIndependentlyComputedOpenSSLDigest() throws {
        let certificate = try makeFixtureCertificate()
        let hash = try XCTUnwrap(PublicKeyPinner.spkiHash(for: certificate))
        XCTAssertEqual(hash, Self.fixtureCorrectPin)
    }

    // MARK: - Scenario 6: SPKI extraction correctness — RSA-4096 (GTS Root R1 key type)

    func test_spkiHash_rsa4096_matchesIndependentlyComputedOpenSSLDigest() throws {
        let certificate = try makeCertificate(base64: Self.fixtureCertificateRSA4096Base64)
        let hash = try XCTUnwrap(PublicKeyPinner.spkiHash(for: certificate))
        XCTAssertEqual(hash, Self.fixtureCorrectPinRSA4096)
    }

    // MARK: - Scenario 7: SPKI extraction correctness — EC P-384 (GTS Root R4 key type)

    func test_spkiHash_ecP384_matchesIndependentlyComputedOpenSSLDigest() throws {
        let certificate = try makeCertificate(base64: Self.fixtureCertificateECP384Base64)
        let hash = try XCTUnwrap(PublicKeyPinner.spkiHash(for: certificate))
        XCTAssertEqual(hash, Self.fixtureCorrectPinECP384)
    }

    // MARK: - Scenario 7b: SPKI extraction correctness — EC P-256

    func test_spkiHash_ecP256_matchesIndependentlyComputedOpenSSLDigest() throws {
        let certificate = try makeCertificate(base64: Self.fixtureCertificateECP256Base64)
        let hash = try XCTUnwrap(PublicKeyPinner.spkiHash(for: certificate))
        XCTAssertEqual(hash, Self.fixtureCorrectPinECP256)
    }

    // MARK: - Scenario 8: system trust failure is never rescued by a matching pin

    ///
    /// The additive property under direct test: pinning must never rescue a
    /// chain system trust has already rejected. Unlike `makeFixtureTrust()`,
    /// this deliberately does NOT add the fixture certificate as a trust
    /// anchor, so `SecTrustEvaluateWithError` fails on it (an unanchored
    /// self-signed cert isn't trusted). A pin set that DOES match the
    /// fixture's SPKI hash is attached regardless — if `evaluate` ever
    /// dropped the `guard systemTrustPasses else { return false }` short
    /// circuit, this is the test that would catch it; every other test in
    /// this file would stay green.
    func test_evaluate_systemTrustFails_matchingPinDoesNotRescue_returnsFalse() throws {
        let certificate = try makeFixtureCertificate()
        var trust: SecTrust?
        let status = SecTrustCreateWithCertificates(
            certificate,
            SecPolicyCreateSSL(true, Self.fixtureHost as CFString),
            &trust
        )
        XCTAssertEqual(status, errSecSuccess)
        let untrustedTrust = try XCTUnwrap(trust)

        var systemTrustError: CFError?
        if SecTrustEvaluateWithError(untrustedTrust, &systemTrustError) {
            // The un-anchored fixture unexpectedly passed system trust (e.g.
            // some quirk of the host's trust store) — force a deterministic
            // failure by restricting anchors to an unrelated certificate.
            let unrelatedAnchor = try makeCertificate(base64: Self.unrelatedAnchorCertificateBase64)
            SecTrustSetAnchorCertificates(untrustedTrust, [unrelatedAnchor] as CFArray)
            SecTrustSetAnchorCertificatesOnly(untrustedTrust, true)

            var forcedError: CFError?
            XCTAssertFalse(
                SecTrustEvaluateWithError(untrustedTrust, &forcedError),
                "expected system trust to fail for a deliberately untrusted fixture"
            )
        }

        let pinner = PublicKeyPinner(
            pins: [Self.fixtureHost: [Self.fixtureCorrectPin]],
            expiry: Date.distantFuture,
            now: { Date.distantPast }
        )

        XCTAssertFalse(pinner.evaluate(serverTrust: untrustedTrust, host: Self.fixtureHost))
    }

    // MARK: - PinningURLSessionDelegate

    //
    // `URLProtectionSpace` has no public initializer that accepts a
    // `SecTrust`, and (verified experimentally) it also isn't KVC-settable
    // for the `serverTrust` key on this platform — the OS only ever
    // populates it while building a real challenge during a live TLS
    // handshake. So the server-trust scenarios below drive
    // `PinningURLSessionDelegate.decide`, the small internal seam the
    // delegate's `urlSession(_:didReceive:completionHandler:)` calls into,
    // directly with a real `SecTrust` fixture instead of a fabricated
    // `URLAuthenticationChallenge`. The non-server-trust scenario doesn't
    // need a trust at all, so it exercises the full delegate method through
    // a real challenge.

    private final class StubAuthenticationChallengeSender: NSObject, URLAuthenticationChallengeSender {
        func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
        func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
        func cancel(_ challenge: URLAuthenticationChallenge) {}
    }

    private func makeChallenge(protectionSpace: URLProtectionSpace) -> URLAuthenticationChallenge {
        URLAuthenticationChallenge(
            protectionSpace: protectionSpace,
            proposedCredential: nil,
            previousFailureCount: 0,
            failureResponse: nil,
            error: nil,
            sender: StubAuthenticationChallengeSender()
        )
    }

    func test_delegate_serverTrustChallenge_pinnerReturnsTrue_usesCredential() throws {
        let trust = try makeFixtureTrust()
        let pinner = PublicKeyPinner(
            pins: [Self.fixtureHost: [Self.fixtureCorrectPin]],
            expiry: .distantFuture,
            now: { .distantPast }
        )
        let delegate = PinningURLSessionDelegate(pinner: pinner)

        let (disposition, credential) = delegate.decide(
            authenticationMethod: NSURLAuthenticationMethodServerTrust,
            serverTrust: trust,
            host: Self.fixtureHost
        )

        XCTAssertEqual(disposition, .useCredential)
        XCTAssertNotNil(credential)
    }

    func test_delegate_serverTrustChallenge_pinnerReturnsFalse_cancelsChallenge() throws {
        let trust = try makeFixtureTrust()
        let pinner = PublicKeyPinner(
            pins: [Self.fixtureHost: [Self.wrongPin]],
            expiry: .distantFuture,
            now: { .distantPast }
        )
        let delegate = PinningURLSessionDelegate(pinner: pinner)

        let (disposition, credential) = delegate.decide(
            authenticationMethod: NSURLAuthenticationMethodServerTrust,
            serverTrust: trust,
            host: Self.fixtureHost
        )

        XCTAssertEqual(disposition, .cancelAuthenticationChallenge)
        XCTAssertNil(credential)
    }

    func test_delegate_serverTrustChallenge_nilTrust_cancelsChallenge() {
        let pinner = PublicKeyPinner(pins: [:], expiry: .distantFuture, now: { .distantPast })
        let delegate = PinningURLSessionDelegate(pinner: pinner)

        // A server-trust challenge with no trust object must fail closed
        // (cancel), not defer to platform default handling.
        let (disposition, credential) = delegate.decide(
            authenticationMethod: NSURLAuthenticationMethodServerTrust,
            serverTrust: nil,
            host: Self.fixtureHost
        )

        XCTAssertEqual(disposition, .cancelAuthenticationChallenge)
        XCTAssertNil(credential)
    }

    func test_delegate_nonServerTrustChallenge_performsDefaultHandling() {
        let pinner = PublicKeyPinner(pins: [:], expiry: .distantFuture, now: { .distantPast })
        let delegate = PinningURLSessionDelegate(pinner: pinner)
        let space = URLProtectionSpace(
            host: Self.fixtureHost,
            port: 443,
            protocol: "https",
            realm: nil,
            authenticationMethod: NSURLAuthenticationMethodHTTPBasic
        )
        let challenge = makeChallenge(protectionSpace: space)

        let calledCompletionHandler = expectation(description: "completionHandler called")
        delegate.urlSession(.shared, didReceive: challenge) { disposition, credential in
            XCTAssertEqual(disposition, .performDefaultHandling)
            XCTAssertNil(credential)
            calledCompletionHandler.fulfill()
        }
        wait(for: [calledCompletionHandler], timeout: 1)
    }
}
