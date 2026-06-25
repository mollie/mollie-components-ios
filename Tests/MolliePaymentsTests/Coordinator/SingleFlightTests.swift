import Foundation
import XCTest
@testable import MollieCore
@testable import MolliePayments

final class SingleFlightTests: XCTestCase {
    func test_guarded_singleCall_executes() async throws {
        let singleFlight = SingleFlight()

        let result = try await singleFlight.guarded { 42 }

        XCTAssertEqual(result, 42)
    }

    func test_guarded_concurrentSecondCall_throwsInvalidConfiguration() async throws {
        let singleFlight = SingleFlight()
        let gate = AsyncGate()

        async let first: Int = singleFlight.guarded {
            await gate.wait()
            return 1
        }

        // Give the first call time to start and set inFlight = true.
        try await Task.sleep(nanoseconds: 10_000_000)

        do {
            _ = try await singleFlight.guarded { 2 }
            XCTFail("Expected second call to throw .invalidConfiguration")
        } catch let MollieError.invalidConfiguration(field, reason) {
            XCTAssertEqual(field, "submit")
            XCTAssertTrue(reason.contains("already in progress"))
        } catch {
            XCTFail("Expected MollieError.invalidConfiguration, got \(error)")
        }

        await gate.open()
        let firstResult = try await first
        XCTAssertEqual(firstResult, 1)
    }

    func test_guarded_sequentialAfterCompletion_executes() async throws {
        let singleFlight = SingleFlight()

        let first = try await singleFlight.guarded { "first" }
        let second = try await singleFlight.guarded { "second" }

        XCTAssertEqual(first, "first")
        XCTAssertEqual(second, "second")
    }

    func test_guarded_throwingOperation_releasesFlight() async throws {
        let singleFlight = SingleFlight()

        do {
            _ = try await singleFlight.guarded { () -> Int in
                throw MollieError.timeout(operation: "test")
            }
            XCTFail("Expected throw")
        } catch {
            // Expected.
        }

        // After the throw, the flight should be released and a new call should succeed.
        let result = try await singleFlight.guarded { 99 }
        XCTAssertEqual(result, 99)
    }
}

/// Minimal async gate to coordinate concurrent test scenarios.
private actor AsyncGate {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let pending = continuations
        continuations.removeAll()
        for continuation in pending {
            continuation.resume()
        }
    }
}
