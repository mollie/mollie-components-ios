import Foundation

/// Parses a user-typed `MM/YY` (or `MM/YYYY`) expiry into integer month + year
/// fields suitable for `CardSubmissionData`.
///
/// Rejects: malformed strings (no slash, non-numeric), month outside 1...12,
/// past months, and years too far in the future to be a real card expiry.
/// "Too far" is conservative — 20 years from the current year — so the form
/// rejects fat-finger typos like `12/99` (interpreted as 2099) while still
/// accepting reasonable five-year-out cards.
package enum ExpiryParser {
    package struct Parsed: Equatable {
        package let month: Int
        package let year: Int
    }

    package enum ParseError: Error, Equatable {
        case malformed
        case monthOutOfRange
        case pastMonth
        case farFuture
    }

    /// Inject `now` and `calendar` so unit tests don't depend on the wall
    /// clock. Defaults work in production.
    package static func parse(
        _ input: String,
        now: Date = Date(),
        calendar: Calendar = .init(identifier: .gregorian)
    ) -> Result<Parsed, ParseError> {
        // Reject any character outside `[0-9/]` up front. Catches double-
        // slash inputs (`12//27`), letters, smart punctuation pasted from
        // a clipboard, and stops `split(separator: "/")` from silently
        // collapsing repeated slashes into one delimiter. Trailing-slash
        // ergonomics for in-progress typing (`12/`) are handled by the
        // count-check below — the gate only blocks junk characters.
        guard input.allSatisfy({ ($0.isASCII && $0.isNumber) || $0 == "/" }) else {
            return .failure(.malformed)
        }
        // Exactly one `/` separator — reject `12//27` and `/12/27`.
        let slashCount = input.reduce(0) { $1 == "/" ? $0 + 1 : $0 }
        guard slashCount == 1 else { return .failure(.malformed) }

        let parts = input.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2 else { return .failure(.malformed) }

        let monthRaw = parts[0].trimmingCharacters(in: .whitespaces)
        let yearRaw = parts[1].trimmingCharacters(in: .whitespaces)
        guard let month = Int(monthRaw),
              let yearSuffix = Int(yearRaw),
              monthRaw.allSatisfy({ $0.isASCII && $0.isNumber }),
              yearRaw.allSatisfy({ $0.isASCII && $0.isNumber })
        else {
            return .failure(.malformed)
        }

        guard (1 ... 12).contains(month) else { return .failure(.monthOutOfRange) }

        let year = yearSuffix < 100 ? 2000 + yearSuffix : yearSuffix
        let components = calendar.dateComponents([.year, .month], from: now)
        guard let currentYear = components.year, let currentMonth = components.month else {
            return .failure(.malformed)
        }

        if year < currentYear || (year == currentYear && month < currentMonth) {
            return .failure(.pastMonth)
        }
        if year > currentYear + 20 {
            return .failure(.farFuture)
        }
        return .success(Parsed(month: month, year: year))
    }
}
