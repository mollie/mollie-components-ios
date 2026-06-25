import XCTest
@testable import MollieCore

final class MollieErrorTests: XCTestCase {
    func test_unauthorized_hasDescription() {
        let error = MollieError.api(.unauthorized)
        XCTAssertNotNil(error.errorDescription)
    }

    func test_forbidden_hasDescription() {
        XCTAssertNotNil(MollieError.api(.forbidden).errorDescription)
    }

    func test_notFound_hasDescription() {
        XCTAssertNotNil(MollieError.api(.notFound).errorDescription)
    }

    func test_serverError_hasDescription() {
        XCTAssertNotNil(MollieError.api(.serverError(500)).errorDescription)
    }

    func test_conflict_withRetryAfter_hasDescription() {
        let error = MollieError.api(.conflict(retryAfter: 2))
        XCTAssertTrue(error.errorDescription?.contains("2") == true)
    }

    func test_conflict_withoutRetryAfter_hasDescription() {
        XCTAssertNotNil(MollieError.api(.conflict(retryAfter: nil)).errorDescription)
    }

    func test_rateLimited_withRetryAfter_hasDescription() {
        let error = MollieError.api(.rateLimited(retryAfter: 30))
        XCTAssertTrue(error.errorDescription?.contains("30") == true)
    }

    func test_rateLimited_withoutRetryAfter_hasDescription() {
        XCTAssertNotNil(MollieError.api(.rateLimited(retryAfter: nil)).errorDescription)
    }

    func test_validationFailed_withViolations_includesFieldNamesInDescription() {
        let violations = [Violation(name: "amount", reason: "must be positive")]
        let error = MollieError.api(.validationFailed(violations))
        XCTAssertTrue(error.errorDescription?.contains("amount") == true)
        XCTAssertTrue(error.errorDescription?.contains("must be positive") == true)
    }

    func test_validationFailed_withNoViolations_hasDescription() {
        XCTAssertNotNil(MollieError.api(.validationFailed([])).errorDescription)
    }

    func test_invalidClientToken_includesReasonInDescription() {
        let error = MollieError.invalidClientToken(reason: "not valid base64")
        XCTAssertTrue(error.errorDescription?.contains("not valid base64") == true)
    }

    func test_apiError_equatable_sameCase() {
        XCTAssertEqual(MollieError.APIError.unauthorized, .unauthorized)
    }

    func test_apiError_equatable_differentCase() {
        XCTAssertNotEqual(MollieError.APIError.unauthorized, .forbidden)
    }

    func test_apiError_equatable_validationFailed_sameViolations() {
        let violations = [Violation(name: "x", reason: "y")]
        XCTAssertEqual(MollieError.APIError.validationFailed(violations), .validationFailed(violations))
    }

    func test_apiError_equatable_conflict_sameRetryAfter() {
        XCTAssertEqual(MollieError.APIError.conflict(retryAfter: 1), .conflict(retryAfter: 1))
    }

    func test_apiError_equatable_conflict_differentRetryAfter() {
        XCTAssertNotEqual(MollieError.APIError.conflict(retryAfter: 1), .conflict(retryAfter: 2))
    }

    func test_apiError_equatable_rateLimited_sameRetryAfter() {
        XCTAssertEqual(MollieError.APIError.rateLimited(retryAfter: 30), .rateLimited(retryAfter: 30))
    }

    func test_apiError_equatable_rateLimited_differentRetryAfter() {
        XCTAssertNotEqual(MollieError.APIError.rateLimited(retryAfter: 10), .rateLimited(retryAfter: 30))
    }

    func test_timeout_hasDescription() {
        let error = MollieError.timeout(operation: "session-polling")
        XCTAssertTrue(error.errorDescription?.contains("session-polling") == true)
    }

    func test_sessionExpired_hasDescription() {
        XCTAssertNotNil(MollieError.sessionExpired.errorDescription)
    }

    func test_sessionFailed_withProblemDetails_hasDescription() {
        let problem = ProblemDetails(
            type: nil,
            title: "Session failed",
            detail: "Card declined.",
            status: 422,
            instance: nil
        )
        let error = MollieError.sessionFailed(problem)
        XCTAssertTrue(error.errorDescription?.contains("Card declined.") == true)
    }

    func test_sessionFailed_nilProblemDetails_hasDescription() {
        XCTAssertNotNil(MollieError.sessionFailed(nil).errorDescription)
    }

    func test_sessionCancelled_hasDescription() {
        XCTAssertNotNil(MollieError.sessionCancelled.errorDescription)
    }

    func test_tokenizationFailed_hasDescription() {
        let error = MollieError.tokenizationFailed(reason: "invalid card number", underlying: nil)
        XCTAssertTrue(error.errorDescription?.contains("invalid card number") == true)
    }

    func test_threeDSFailed_hasDescription() {
        let error = MollieError.threeDSFailed(reason: .challengeFailed)
        XCTAssertNotNil(error.errorDescription)
    }

    func test_userCancelled_hasDescription() {
        XCTAssertNotNil(MollieError.userCancelled.errorDescription)
    }

    func test_invalidConfiguration_hasDescription() {
        let error = MollieError.invalidConfiguration(field: "clientToken", reason: "missing")
        XCTAssertTrue(error.errorDescription?.contains("clientToken") == true)
        XCTAssertTrue(error.errorDescription?.contains("missing") == true)
    }

    func test_threeDSFailureReason_sdkError_equatable_sameMessage() {
        XCTAssertEqual(
            ThreeDSFailureReason.sdkError(message: "boom"),
            ThreeDSFailureReason.sdkError(message: "boom")
        )
    }

    func test_threeDSFailureReason_sdkError_equatable_differentMessage() {
        XCTAssertNotEqual(
            ThreeDSFailureReason.sdkError(message: "boom"),
            ThreeDSFailureReason.sdkError(message: "kaboom")
        )
    }

    // MARK: - Documentation completeness

    /// Makes the error-case set impossible to change silently, so the
    /// documented catalog (the `///` doc comments + the DocC `HandlingErrors`
    /// article) gets a forced review whenever a case is added or removed.
    /// `///` and markdown prose can't be introspected at runtime, so this
    /// test does NOT validate their content — instead it exhaustively
    /// switches over a representative instance of every `MollieError`,
    /// `MollieError.APIError`, and `ThreeDSFailureReason` case with no
    /// `default` arm. Adding or removing a case breaks the switch's
    /// exhaustiveness check at compile time, which is the signal to whoever
    /// changes the enum to update the docs. (Keeping the prose accurate is
    /// still a human step — this guards the trigger, not the copy.)
    ///
    /// Every arm asserts the case carries a non-empty `errorDescription`
    /// so the developer/log copy can never regress to empty either.
    func test_errorCatalog_isExhaustiveOverEveryCase() {
        let violation = Violation(name: "cardNumber", reason: "is invalid")
        let problem = ProblemDetails(title: "invalid_configuration", detail: "Unsafe 3DS challenge URL")

        // Every MollieError case — the compiler enforces exhaustiveness.
        let allErrors: [MollieError] = [
            .network(URLError(.notConnectedToInternet)),
            .api(.unauthorized),
            .decoding(DecodingError.valueNotFound(String.self, .init(codingPath: [], debugDescription: "x"))),
            .invalidClientToken(reason: "not base64"),
            .timeout(operation: "session-polling"),
            .sessionExpired,
            .sessionFailed(problem),
            .sessionCancelled,
            .tokenizationFailed(reason: "invalid card number", underlying: nil),
            .threeDSFailed(reason: .challengeFailed),
            .userCancelled,
            .invalidConfiguration(field: "number", reason: "is invalid"),
            .unknown(URLError(.unknown)),
        ]

        for error in allErrors {
            switch error {
            case .network,
                 .api,
                 .decoding,
                 .invalidClientToken,
                 .timeout,
                 .sessionExpired,
                 .sessionFailed,
                 .sessionCancelled,
                 .tokenizationFailed,
                 .threeDSFailed,
                 .userCancelled,
                 .invalidConfiguration,
                 .unknown:
                XCTAssertFalse(error.errorDescription?.isEmpty ?? true)
            }
        }

        // Every nested APIError case.
        let allAPIErrors: [MollieError.APIError] = [
            .unauthorized,
            .forbidden,
            .notFound,
            .validationFailed([violation]),
            .conflict(retryAfter: 5),
            .rateLimited(retryAfter: 30),
            .serverError(500),
        ]

        for apiError in allAPIErrors {
            switch apiError {
            case .unauthorized,
                 .forbidden,
                 .notFound,
                 .validationFailed,
                 .conflict,
                 .rateLimited,
                 .serverError:
                XCTAssertFalse(MollieError.api(apiError).errorDescription?.isEmpty ?? true)
            }
        }

        // Every ThreeDSFailureReason case.
        let allThreeDSReasons: [ThreeDSFailureReason] = [
            .challengeFailed,
            .timeout,
            .sdkError(message: "navigation_error_1"),
            .unknown(code: "42", message: "boom"),
        ]

        for reason in allThreeDSReasons {
            switch reason {
            case .challengeFailed,
                 .timeout,
                 .sdkError,
                 .unknown:
                XCTAssertFalse(MollieError.threeDSFailed(reason: reason).errorDescription?.isEmpty ?? true)
            }
        }
    }
}
