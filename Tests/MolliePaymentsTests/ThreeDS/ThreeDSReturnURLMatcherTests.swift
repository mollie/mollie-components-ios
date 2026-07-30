import XCTest
@testable import MolliePayments

final class ThreeDSReturnURLMatcherTests: XCTestCase {
    private let matcher = ThreeDSReturnURLMatcher()

    func test_matches_validReturnURL_returnsTrue() throws {
        let url = try XCTUnwrap(URL(string: "https://secure-3ds.mollie.com/3ds/return?status=authenticated"))
        XCTAssertTrue(matcher.matches(url))
    }

    func test_matches_unrelatedURL_returnsFalse() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/foo"))
        XCTAssertFalse(matcher.matches(url))
    }

    func test_matches_mollieNonReturnPath_returnsFalse() throws {
        let url = try XCTUnwrap(URL(string: "https://secure-3ds.mollie.com/sessions/abc"))
        XCTAssertFalse(matcher.matches(url))
    }

    // MARK: - Production host allow-list

    func test_matches_apiMollieCom_isNotInProductionAllowList() throws {
        // `api.mollie.com` used to be in the prod allow-list "for test
        // fixtures." It must not be — the canonical 3DS return host is
        // `secure-3ds.mollie.com`. Production matcher rejects it.
        let url = try XCTUnwrap(URL(string: "https://api.mollie.com/3ds/return?status=authenticated"))
        XCTAssertFalse(matcher.matches(url))
    }

    #if DEBUG
        func test_matches_testFixtureHost_acceptedViaSPI() throws {
            // SPI seam exists for tests / fixtures pinned to legacy hosts.
            let fixtureMatcher = ThreeDSReturnURLMatcher(testFixtureHosts: ["api.mollie.com"])
            let url = try XCTUnwrap(URL(string: "https://api.mollie.com/3ds/return?status=authenticated"))
            XCTAssertTrue(fixtureMatcher.matches(url))
        }
    #endif

    // MARK: - Path matching

    func test_matches_exactReturnPath_returnsTrue() throws {
        let url = try XCTUnwrap(URL(string: "https://secure-3ds.mollie.com/3ds/return"))
        XCTAssertTrue(matcher.matches(url))
    }

    func test_matches_returnSubPath_returnsTrue() throws {
        let url = try XCTUnwrap(URL(string: "https://secure-3ds.mollie.com/3ds/return/xyz"))
        XCTAssertTrue(matcher.matches(url))
    }

    func test_matches_returnFakePath_returnsFalse() throws {
        // `/3ds/return-fake` must NOT match — previously `hasPrefix("/3ds/return")`
        // accepted it, opening a path-confusion vector where an attacker-
        // controlled segment trailing `/3ds/return` looked legit.
        let url = try XCTUnwrap(URL(string: "https://secure-3ds.mollie.com/3ds/return-fake"))
        XCTAssertFalse(matcher.matches(url))
    }

    func test_matches_returnFOOPath_returnsFalse() throws {
        let url = try XCTUnwrap(URL(string: "https://secure-3ds.mollie.com/3ds/returnFOO"))
        XCTAssertFalse(matcher.matches(url))
    }

    func test_matches_returnTrailingSlash_returnsTrue() throws {
        // `/3ds/return/` — trailing slash form must match (treated as the
        // canonical return path with an empty child segment).
        let url = try XCTUnwrap(URL(string: "https://secure-3ds.mollie.com/3ds/return/"))
        XCTAssertTrue(matcher.matches(url))
    }

    func test_parseResult_authenticated_returnsAuthenticated() throws {
        let url = try XCTUnwrap(URL(string: "https://secure-3ds.mollie.com/3ds/return?status=authenticated"))
        XCTAssertEqual(matcher.parseResult(from: url), .authenticated)
    }

    func test_parseResult_failedWithReason_returnsFailedSdkError() throws {
        let url = try XCTUnwrap(URL(string: "https://secure-3ds.mollie.com/3ds/return?status=failed&reason=decline"))
        XCTAssertEqual(matcher.parseResult(from: url), .failed(reason: .sdkError(message: "decline")))
    }

    func test_parseResult_failedWithoutReason_returnsFailedChallengeFailed() throws {
        let url = try XCTUnwrap(URL(string: "https://secure-3ds.mollie.com/3ds/return?status=failed"))
        XCTAssertEqual(matcher.parseResult(from: url), .failed(reason: .challengeFailed))
    }

    func test_parseResult_unknownStatus_returnsFailed() throws {
        let url = try XCTUnwrap(URL(string: "https://secure-3ds.mollie.com/3ds/return?status=weird"))
        XCTAssertEqual(
            matcher.parseResult(from: url),
            .failed(reason: .sdkError(message: "Unknown 3DS return status: weird"))
        )
    }

    func test_parseResult_missingStatus_returnsCancelled() throws {
        let url = try XCTUnwrap(URL(string: "https://secure-3ds.mollie.com/3ds/return"))
        XCTAssertEqual(matcher.parseResult(from: url), .cancelled)
    }
}
