import XCTest
@testable import MolliePaymentsUI

final class ExpiryParserTests: XCTestCase {
    private let now: Date = {
        // Pinned anchor so the suite doesn't drift with the wall clock.
        // 2026-05-21 (matches the Phase 3 plan date).
        var components = DateComponents()
        components.year = 2026
        components.month = 5
        components.day = 21
        return Calendar(identifier: .gregorian).date(from: components)!
        // swiftlint:disable:previous force_unwrapping
    }()

    // MARK: - Happy paths

    func test_parses_twoDigitYear() {
        let result = ExpiryParser.parse("12/30", now: now)
        XCTAssertEqual(try? result.get(), .init(month: 12, year: 2030))
    }

    func test_parses_fourDigitYear() {
        let result = ExpiryParser.parse("01/2030", now: now)
        XCTAssertEqual(try? result.get(), .init(month: 1, year: 2030))
    }

    func test_parses_leadingZeroMonth() {
        let result = ExpiryParser.parse("05/27", now: now)
        XCTAssertEqual(try? result.get(), .init(month: 5, year: 2027))
    }

    func test_parses_currentMonth_isValid() {
        // Same month, same year — still a valid card.
        let result = ExpiryParser.parse("05/26", now: now)
        XCTAssertEqual(try? result.get(), .init(month: 5, year: 2026))
    }

    // MARK: - Format errors

    func test_missingSlash_isMalformed() {
        XCTAssertEqual(ExpiryParser.parse("1226", now: now), .failure(.malformed))
    }

    func test_nonNumericMonth_isMalformed() {
        XCTAssertEqual(ExpiryParser.parse("AA/27", now: now), .failure(.malformed))
    }

    func test_nonNumericYear_isMalformed() {
        XCTAssertEqual(ExpiryParser.parse("12/YY", now: now), .failure(.malformed))
    }

    func test_emptyString_isMalformed() {
        XCTAssertEqual(ExpiryParser.parse("", now: now), .failure(.malformed))
    }

    // MARK: - Range errors

    func test_monthZero_outOfRange() {
        XCTAssertEqual(ExpiryParser.parse("00/27", now: now), .failure(.monthOutOfRange))
    }

    func test_month13_outOfRange() {
        XCTAssertEqual(ExpiryParser.parse("13/27", now: now), .failure(.monthOutOfRange))
    }

    func test_pastMonth_sameYear_rejected() {
        // Now is May 2026; April 2026 is past.
        XCTAssertEqual(ExpiryParser.parse("04/26", now: now), .failure(.pastMonth))
    }

    func test_pastYear_rejected() {
        XCTAssertEqual(ExpiryParser.parse("12/25", now: now), .failure(.pastMonth))
    }

    func test_farFutureYear_rejected() {
        // Twenty years from now (2046) is the upper bound — 2047+ is rejected
        // as a fat-finger typo. Catches the classic `12/99` mistake users
        // make on small numeric keypads.
        XCTAssertEqual(ExpiryParser.parse("12/99", now: now), .failure(.farFuture))
    }

    func test_twentyYearsOut_accepted() {
        // 2046 is the boundary — still accepted.
        XCTAssertEqual(try? ExpiryParser.parse("12/46", now: now).get(), .init(month: 12, year: 2046))
    }

    func test_parse_doubleSlash_rejected() {
        // `split(separator: "/")` with `omittingEmptySubsequences` would
        // silently fold `12//27` to `["12", "27"]`. The validator must
        // reject the input as malformed rather than accept the user's
        // fat-finger as a valid date.
        XCTAssertEqual(ExpiryParser.parse("12//27", now: now), .failure(.malformed))
    }

    func test_parse_leadingSlash_rejected() {
        XCTAssertEqual(ExpiryParser.parse("/12/27", now: now), .failure(.malformed))
    }

    func test_parse_arabicIndicDigits_rejected() {
        // Arabic-Indic numerals satisfy `Character.isNumber` but
        // `Int(string)` only parses ASCII digits — the previous guard
        // accepted them on the `.allSatisfy(\.isNumber)` check and then
        // crashed (or silently returned `.malformed`) on the `Int(...)`
        // pass. ASCII-gated rejection makes the failure explicit.
        XCTAssertEqual(
            ExpiryParser.parse("\u{0661}\u{0662}/\u{0662}\u{0667}", now: now),
            .failure(.malformed)
        )
    }
}
