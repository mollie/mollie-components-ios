import XCTest
@testable import MolliePayments

final class CardSubmissionDataTests: XCTestCase {
    func test_equatable_sameFields_isEqual() {
        let lhs = CardSubmissionData(
            cardholderName: "Jane Doe",
            cardNumber: "4242424242424242",
            expiryMonth: 12,
            expiryYear: 2030,
            cvc: "123"
        )
        let rhs = CardSubmissionData(
            cardholderName: "Jane Doe",
            cardNumber: "4242424242424242",
            expiryMonth: 12,
            expiryYear: 2030,
            cvc: "123"
        )

        XCTAssertEqual(lhs, rhs)
    }

    func test_equatable_differentCardNumber_isNotEqual() {
        let lhs = CardSubmissionData(
            cardholderName: "Jane Doe",
            cardNumber: "4242424242424242",
            expiryMonth: 12,
            expiryYear: 2030,
            cvc: "123"
        )
        let rhs = CardSubmissionData(
            cardholderName: "Jane Doe",
            cardNumber: "5555555555554444",
            expiryMonth: 12,
            expiryYear: 2030,
            cvc: "123"
        )

        XCTAssertNotEqual(lhs, rhs)
    }
}
