import Foundation
import MollieCore
import XCTest
@testable import MolliePayments

final class CardTokenizerTests: XCTestCase {
    private func makeSubmissionData() -> CardSubmissionData {
        CardSubmissionData(
            cardholderName: "Jane Doe",
            cardNumber: "4242424242424242",
            expiryMonth: 12,
            expiryYear: 2030,
            cvc: "123"
        )
    }

    private func makeTokenizer(mock: MockHTTPClient) -> CardTokenizer {
        CardTokenizer(httpClient: mock, profileToken: "pfl_test", testmode: true)
    }

    func test_tokenize_success_returnsToken() async throws {
        let mock = MockHTTPClient()
        let expected = CardToken(value: "tok_abc")
        mock.enqueue(expected)
        let tokenizer = makeTokenizer(mock: mock)

        let result = try await tokenizer.tokenize(makeSubmissionData())

        XCTAssertEqual(result, expected)
    }

    func test_tokenize_validationFailed_throwsTokenizationFailed() async throws {
        let mock = MockHTTPClient()
        let violation = try decodeViolation(name: "cardNumber", reason: "invalid")
        mock.enqueue(error: MollieError.api(.validationFailed([violation])))
        let tokenizer = makeTokenizer(mock: mock)

        do {
            _ = try await tokenizer.tokenize(makeSubmissionData())
            XCTFail("Expected tokenization to throw")
        } catch let MollieError.tokenizationFailed(reason, underlying) {
            XCTAssertEqual(reason, "cardNumber: invalid")
            guard let underlyingMollie = underlying as? MollieError else {
                XCTFail("Underlying error should be MollieError, got: \(String(describing: underlying))")
                return
            }
            if case let .api(.validationFailed(violations)) = underlyingMollie {
                XCTAssertEqual(violations, [violation])
            } else {
                XCTFail("Underlying error should be MollieError.api(.validationFailed)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private func decodeViolation(name: String, reason: String) throws -> Violation {
        let json = Data(#"{"name":"\#(name)","reason":"\#(reason)"}"#.utf8)
        return try JSONDecoder().decode(Violation.self, from: json)
    }

    func test_tokenize_networkError_propagatesAsIs() async {
        let mock = MockHTTPClient()
        let urlError = URLError(.notConnectedToInternet)
        mock.enqueue(error: MollieError.network(urlError))
        let tokenizer = makeTokenizer(mock: mock)

        do {
            _ = try await tokenizer.tokenize(makeSubmissionData())
            XCTFail("Expected tokenization to throw")
        } catch let MollieError.network(error) {
            XCTAssertEqual(error.code, urlError.code)
        } catch {
            XCTFail("Network error should propagate unchanged, got: \(error)")
        }
    }
}
