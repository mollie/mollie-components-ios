import Foundation
import XCTest
@testable import MollieCore

// NOTE: This file is duplicated at Tests/MollieCoreTests/Networking/MockHTTPClient.swift
// because SwiftPM test targets cannot share code without a dedicated test-support target.
// Future cleanup: extract to a `MollieTestKit` target and import from both test suites.
// Keep the two copies in sync when modifying.

/// Queue-based `HTTPClient` test double.
///
/// Each call to `perform` pops the head of the queue and either returns the
/// pre-recorded value (if the response type matches `T`) or throws the
/// pre-recorded error. Tests `enqueue` results in the order they should be
/// returned.
final class MockHTTPClient: HTTPClient, @unchecked Sendable {
    enum Outcome {
        case success(Any)
        case failure(Error)
    }

    /// Captured request metadata for one `perform(_:)` call.
    ///
    /// Pre-fix, the mock never inspected the request — so a happy-path test
    /// could pass even if the SDK shipped the wrong URL or body. That's
    /// exactly the failure mode from the production "access denied" incident
    /// (tokenizer pointed at the legacy `/v1/tokens` path). Capturing
    /// (path, method, body) makes those drifts loud at the test level.
    ///
    /// Body is type-erased via re-encoding to `Data` at capture time so
    /// tests can decode into whatever concrete request type they expect
    /// without forcing the mock to know about each `Encodable` shape.
    struct CapturedRequest {
        let path: String
        let method: HTTPMethod
        /// JSON-encoded body, or `nil` if the endpoint had no body
        /// (GET, or POST/PATCH with `body: nil`). Encoded via the same
        /// `JSONEncoder()` path used by `Endpoint.asURLRequest`.
        let body: Data?
    }

    private let lock = NSLock()
    private var queue: [Outcome] = []
    private(set) var callCount = 0
    /// Every `perform(_:)` call appends its (path, method, body) here.
    /// Tests assert on `capturedRequests.last` for the most recent call
    /// or filter the array to find a specific endpoint.
    private(set) var capturedRequests: [CapturedRequest] = []

    func enqueue(_ value: some Any) {
        lock.lock()
        defer { lock.unlock() }
        queue.append(.success(value))
    }

    func enqueue(error: Error) {
        lock.lock()
        defer { lock.unlock() }
        queue.append(.failure(error))
    }

    /// Enqueue a single value to be returned for every subsequent call.
    /// Useful for "mock always returns X" scenarios.
    func enqueueRepeating(_ value: some Any) {
        lock.lock()
        defer { lock.unlock() }
        queue.append(.success(value))
        repeating = .success(value)
    }

    private var repeating: Outcome?

    func perform<T: Decodable>(_ endpoint: Endpoint<T>) async throws -> T {
        lock.lock()
        callCount += 1
        // Capture (path, method, body) before consuming the queue so that
        // even a queue-empty XCTFail path still records the call that
        // tripped the failure — useful when diagnosing why an assertion
        // saw fewer requests than expected.
        let encodedBody = endpoint.body.flatMap { try? JSONEncoder().encode($0) }
        capturedRequests.append(
            CapturedRequest(path: endpoint.path, method: endpoint.method, body: encodedBody)
        )
        let outcome: Outcome
        if queue.isEmpty {
            guard let repeating else {
                lock.unlock()
                // Fail the assertion but let the suite continue rather than
                // crash the whole test process via fatalError.
                XCTFail("MockHTTPClient: response queue is empty for call #\(callCount) — check test setup")
                throw MollieError.network(URLError(.unknown))
            }
            outcome = repeating
        } else {
            outcome = queue.removeFirst()
        }
        lock.unlock()
        switch outcome {
        case let .success(value):
            guard let typed = value as? T else {
                XCTFail(
                    "MockHTTPClient: enqueued value type mismatch (expected \(T.self), got \(type(of: value))) — check test setup"
                )
                throw MollieError.network(URLError(.unknown))
            }
            return typed
        case let .failure(error):
            throw error
        }
    }
}
