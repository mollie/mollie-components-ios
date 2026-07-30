import Foundation
import MollieCore
import XCTest
@testable import MolliePayments

/// Real-endpoint guard for the tokenise charging POST (acceptance finding).
///
/// The existing POST-not-retried guards live in `MollieCoreTests` and use a
/// hand-rolled `StubTokenEndpoint` (a local `.post` Endpoint) because that
/// target cannot import `MolliePayments`. They pin the *client's* behaviour for
/// a POST shape, but they do NOT pin the REAL
/// `TokenizerEndpoint.tokenize(...)` — so flipping that method away from POST,
/// or adding it to `isIdempotent`, would slip past them.
///
/// This target CAN import both `MolliePayments` and `MollieCore`, so it drives
/// the genuine `TokenizerEndpoint.tokenize(...)` through the real
/// `TokenizerClient` (backed by a `URLProtocol` mock) and asserts a single
/// attempt. It turns red if `tokenize`'s HTTP method ever stops being POST or
/// if POST ever becomes idempotent — neither the Sessions Service nor the
/// PCI Tokeniser honours an inbound idempotency key, so retrying the
/// charging POST risks a duplicate charge.
final class TokenizerEndpointRetryGuardTests: XCTestCase {
    private let baseURL = URL(string: "https://api.cc.mollie.com") ?? URL(fileURLWithPath: "/")

    private func makeRealTokenizeEndpoint() -> Endpoint<CardToken> {
        TokenizerEndpoint.tokenize(
            CardSubmissionData(
                cardholderName: "Jane Doe",
                cardNumber: "4242424242424242",
                expiryMonth: 12,
                expiryYear: 2030,
                cvc: "123"
            ),
            profileToken: "pfl_test",
            testmode: true
        )
    }

    func test_realTokenizeEndpoint_transientURLError_isNotRetried_singleAttempt() async {
        // A transient retryable URLError driven through the REAL tokenize
        // endpoint must result in EXACTLY ONE attempt — the charging POST is
        // never auto-retried. Allowing maxAttempts: 3 proves the single attempt
        // comes from the endpoint's method, not from a low retry budget.
        let callCount = TokenizeCallCounter()
        TokenizeMockURLProtocol.handler = { _ in
            callCount.increment()
            throw URLError(.timedOut)
        }
        defer { TokenizeMockURLProtocol.handler = nil }

        let client = TokenizerClient(
            baseURL: baseURL,
            retryPolicy: RetryPolicy(maxAttempts: 3, baseDelay: 0),
            session: TokenizeMockURLProtocol.makeSession()
        )

        do {
            _ = try await client.perform(makeRealTokenizeEndpoint())
            XCTFail("Expected the tokenize POST to throw")
        } catch MollieError.network {
            // POST charge is single-attempt: pins TokenizerEndpoint.tokenize as
            // .post AND absent from isIdempotent. Adding either would retry → red.
            XCTAssertEqual(callCount.value, 1, "Tokenise POST must not be auto-retried")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}

// MARK: - Local URLProtocol mock

//
// SwiftPM test targets cannot share helpers; MollieCoreTests' MockURLProtocol
// is not visible here. This is a minimal local copy so the test can run the
// real TokenizerClient end-to-end. Keep in sync if the core copy changes.

private final class TokenizeCallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0
    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return _value
    }

    func increment() {
        lock.lock()
        defer { lock.unlock() }
        _value += 1
    }
}

private final class TokenizeMockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [TokenizeMockURLProtocol.self]
        return URLSession(configuration: config)
    }

    override static func canInit(with request: URLRequest) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = TokenizeMockURLProtocol.handler else {
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
