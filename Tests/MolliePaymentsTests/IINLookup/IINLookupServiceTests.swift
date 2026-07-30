import Foundation
import MollieCore
import XCTest
@testable import MolliePayments

final class IINLookupServiceTests: XCTestCase {
    func test_lookup_under6digits_returnsNil() async {
        let mock = MockHTTPClient()
        let service = IINLookupService(httpClient: mock, debounceInterval: 0.01)

        let result = await service.lookup(prefix: "12345")

        XCTAssertNil(result)
        XCTAssertEqual(mock.callCount, 0)
    }

    func test_lookup_atLeast6digits_returnsResult() async {
        let mock = MockHTTPClient()
        let expected = IINResult(schemes: [.visa], cardType: .credit, issuingCountry: "NL")
        mock.enqueue(expected)
        let service = IINLookupService(httpClient: mock, debounceInterval: 0.01)

        let result = await service.lookup(prefix: "424242")

        XCTAssertEqual(result, expected)
        XCTAssertEqual(mock.callCount, 1)
    }

    func test_lookup_debounces_rapidCalls() async {
        let mock = MockHTTPClient()
        let expected = IINResult(schemes: [.visa], cardType: .credit, issuingCountry: "NL")
        mock.enqueueRepeating(expected)
        let service = IINLookupService(httpClient: mock, debounceInterval: 0.05)

        async let first = service.lookup(prefix: "424242")
        async let second = service.lookup(prefix: "424243")
        async let third = service.lookup(prefix: "424244")

        _ = await (first, second, third)

        XCTAssertEqual(mock.callCount, 1)
    }

    func test_lookup_httpError_returnsNil() async {
        let mock = MockHTTPClient()
        mock.enqueue(error: MollieError.api(.unauthorized))
        let service = IINLookupService(httpClient: mock, debounceInterval: 0.01)

        let result = await service.lookup(prefix: "424242")

        XCTAssertNil(result)
    }
}
