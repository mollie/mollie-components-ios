import Foundation

/// Luhn check on a digit string. The form calls this on the PAN after
/// stripping spacing to decide whether the submit button is enabled.
///
/// Returns `false` for empty strings and for any non-digit input — the
/// caller is expected to pre-clean PAN input, but defensive programming
/// here is cheap and prevents a bad mask from accepting garbage.
package enum Luhn {
    package static func isValid(_ pan: String) -> Bool {
        guard !pan.isEmpty else { return false }
        // A string of zeros sums to zero and would pass the modulo-10
        // check, but no real-world issuer ships an all-zero PAN. Reject
        // early so an empty masking pass or a bug that inits the buffer
        // with zeros can't false-positive past the length / Luhn gate.
        guard pan.contains(where: { $0 != "0" }) else { return false }
        var sum = 0
        var doubleNext = false
        for character in pan.reversed() {
            guard let digit = character.wholeNumberValue, character.isASCII, character.isNumber else {
                return false
            }
            if doubleNext {
                let doubled = digit * 2
                sum += doubled > 9 ? doubled - 9 : doubled
            } else {
                sum += digit
            }
            doubleNext.toggle()
        }
        return sum % 10 == 0
    }
}
