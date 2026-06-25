import XCTest
@testable import MollieCore

final class ParsedEnumTests: XCTestCase {
    private enum Color: String, Decodable, Equatable {
        case red
        case blue
    }

    private func decode(_ json: String) throws -> ParsedEnum<Color> {
        let data = Data(json.utf8)
        return try JSONDecoder().decode(ParsedEnum<Color>.self, from: data)
    }

    func test_knownValue_decodesAsKnown() throws {
        let result = try decode(#""red""#)
        XCTAssertEqual(result, .known(.red))
    }

    func test_unknownValue_decodesAsUnknown_doesNotThrow() throws {
        let result = try decode(#""green""#)
        XCTAssertEqual(result, .unknown("green"))
    }

    func test_equatable_knownMatchesKnown() {
        XCTAssertEqual(ParsedEnum<Color>.known(.red), .known(.red))
    }

    func test_equatable_knownDoesNotMatchDifferentKnown() {
        XCTAssertNotEqual(ParsedEnum<Color>.known(.red), .known(.blue))
    }

    func test_equatable_unknownMatchesUnknown() {
        XCTAssertEqual(ParsedEnum<Color>.unknown("green"), .unknown("green"))
    }

    func test_equatable_knownDoesNotMatchUnknown() {
        XCTAssertNotEqual(ParsedEnum<Color>.known(.red), .unknown("red"))
    }
}
