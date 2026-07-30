import Foundation
import XCTest
@testable import MolliePayments

final class BINPrefixTableTests: XCTestCase {
    // MARK: - One representative prefix per scheme

    func test_detect_visa() {
        XCTAssertEqual(BINPrefixTable.detect(prefix: "424242"), [.visa])
    }

    func test_detect_mastercard_51to55Range() {
        XCTAssertEqual(BINPrefixTable.detect(prefix: "555544"), [.mastercard])
    }

    func test_detect_mastercard_2221to2720Range() {
        XCTAssertEqual(BINPrefixTable.detect(prefix: "222100"), [.mastercard])
    }

    func test_detect_amex() {
        XCTAssertEqual(BINPrefixTable.detect(prefix: "378282"), [.amex])
    }

    func test_detect_maestro_twoDigitRange() {
        XCTAssertEqual(BINPrefixTable.detect(prefix: "501800"), [.maestro])
    }

    func test_detect_maestro_fourDigitExact() {
        XCTAssertEqual(BINPrefixTable.detect(prefix: "630400"), [.maestro])
    }

    func test_detect_discover_6011() {
        XCTAssertEqual(BINPrefixTable.detect(prefix: "601111"), [.discover])
    }

    func test_detect_dinersClub_300to305Range() {
        XCTAssertEqual(BINPrefixTable.detect(prefix: "305693"), [.dinersClub])
    }

    func test_detect_dinersClub_36() {
        XCTAssertEqual(BINPrefixTable.detect(prefix: "360000"), [.dinersClub])
    }

    func test_detect_jcb() {
        XCTAssertEqual(BINPrefixTable.detect(prefix: "352800"), [.jcb])
    }

    func test_detect_unionPay() {
        // Outside the Discover/UnionPay shared 622126-622925 range (see below),
        // so this is unambiguously UnionPay-only.
        XCTAssertEqual(BINPrefixTable.detect(prefix: "624444"), [.unionPay])
    }

    // MARK: - Ambiguous / co-badge

    /// Discover's published BIN list carries 622126-622925 as its own range for
    /// Discover/UnionPay alliance cards, which sits inside UnionPay's "62" range.
    /// This is a genuine, documented overlap (unlike the other schemes here,
    /// which occupy disjoint ranges) — a real instance of the co-badge case
    /// `detect` must model as a multi-element Set (E1 forward-compat).
    func test_detect_discoverUnionPayAllianceRange_returnsBothSchemes() {
        XCTAssertEqual(BINPrefixTable.detect(prefix: "622126"), [.discover, .unionPay])
        XCTAssertEqual(BINPrefixTable.detect(prefix: "622500"), [.discover, .unionPay])
        XCTAssertEqual(BINPrefixTable.detect(prefix: "622925"), [.discover, .unionPay])
    }

    func test_detect_justOutsideAllianceRange_isUnionPayOnly() {
        XCTAssertEqual(BINPrefixTable.detect(prefix: "622125"), [.unionPay])
        XCTAssertEqual(BINPrefixTable.detect(prefix: "622926"), [.unionPay])
    }

    /// Cartes Bancaires co-badges onto Visa/Mastercard BINs (no distinct
    /// globally-published range of its own), so it can never be produced by
    /// local prefix matching — this is a known, intentional gap. The network
    /// IIN lookup is the authority that can confirm CB co-badging.
    func test_detect_neverReturnsCartesBancairesLocally() {
        XCTAssertEqual(BINPrefixTable.detect(prefix: "497010"), [.visa])
    }

    // MARK: - Unknown

    func test_detect_unknownPrefix_returnsEmpty() {
        XCTAssertEqual(BINPrefixTable.detect(prefix: "123456"), [])
    }

    func test_detect_emptyString_returnsEmpty() {
        XCTAssertEqual(BINPrefixTable.detect(prefix: ""), [])
    }

    func test_detect_nonDigitInput_returnsEmpty() {
        XCTAssertEqual(BINPrefixTable.detect(prefix: "4a4242"), [])
    }

    // MARK: - PCI safety: only the leading digits matter

    func test_detect_fullPAN_stillDetectsFromLeadingDigits() {
        // A full 16-digit PAN must never be required — only the first 6-8
        // digits are meaningful. Passing more must not change or break detection.
        XCTAssertEqual(BINPrefixTable.detect(prefix: "4242424242424242"), [.visa])
    }

    // MARK: - Short, incremental prefixes (as typed live)

    func test_detect_singleDigit_visa() {
        XCTAssertEqual(BINPrefixTable.detect(prefix: "4"), [.visa])
    }
}
