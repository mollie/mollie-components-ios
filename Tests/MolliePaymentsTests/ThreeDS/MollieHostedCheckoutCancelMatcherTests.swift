import XCTest
@testable import MolliePayments

final class MollieHostedCheckoutCancelMatcherTests: XCTestCase {
    private let matcher = MollieHostedCheckoutCancelMatcher()

    // MARK: - matches

    func test_matches_wwwMollieCheckoutWithErrorCode_returnsTrue() throws {
        let url =
            try XCTUnwrap(
                URL(string: "https://www.mollie.com/checkout/credit-card/return?transaction_id=abc&error_code=1008")
            )
        XCTAssertTrue(matcher.matches(url))
    }

    func test_matches_apexMollieCheckoutWithErrorCode_returnsTrue() throws {
        let url = try XCTUnwrap(URL(string: "https://mollie.com/checkout/credit-card/session/x?error_code=1005"))
        XCTAssertTrue(matcher.matches(url))
    }

    func test_matches_payMollieAuthenticatePath_returnsFalse() throws {
        // Critical guard: must NOT match the in-flight 3DS challenge URL,
        // otherwise we'd dismiss the WebView before the user can authenticate.
        let url = try XCTUnwrap(URL(string: "https://pay.mollie.nl/payment/prepare-authentication/abc?error_code=1008"))
        XCTAssertFalse(matcher.matches(url))
    }

    func test_matches_mollieCheckoutEmptyErrorCode_returnsFalse() throws {
        // `?error_code=` (empty) carries no signal. Previously this
        // matched and parseResult emitted the useless token `mollie_error_`.
        let url = try XCTUnwrap(URL(string: "https://www.mollie.com/checkout/credit-card/return?error_code="))
        XCTAssertFalse(matcher.matches(url))
    }

    func test_parseResult_emptyErrorCode_returnsFailedChallengeFailed() throws {
        // Defensive: even if a caller reaches parseResult bypassing matches(),
        // an empty code must fall back to challengeFailed, not synthesize a
        // bogus `mollie_error_` diagnostic.
        let url = try XCTUnwrap(URL(string: "https://www.mollie.com/checkout/credit-card/return?error_code="))
        XCTAssertEqual(matcher.parseResult(from: url), .failed(reason: .challengeFailed))
    }

    func test_matches_mollieCheckoutWithoutErrorCode_returnsFalse() throws {
        // Without an error_code we have no signal that this is a terminal
        // state — let it through and rely on other matchers / the merchant
        // return URL to dismiss.
        let url = try XCTUnwrap(URL(string: "https://www.mollie.com/checkout/credit-card/session/x"))
        XCTAssertFalse(matcher.matches(url))
    }

    func test_matches_mollieMarketingPage_returnsFalse() throws {
        // Defensive: the /checkout/ path prefix guards against accidental
        // matches on marketing pages even if a stray error_code appears.
        let url = try XCTUnwrap(URL(string: "https://www.mollie.com/about?error_code=1008"))
        XCTAssertFalse(matcher.matches(url))
    }

    func test_matches_httpScheme_returnsFalse() throws {
        let url = try XCTUnwrap(URL(string: "http://www.mollie.com/checkout/credit-card/return?error_code=1008"))
        XCTAssertFalse(matcher.matches(url))
    }

    func test_matches_unrelatedHost_returnsFalse() throws {
        let url = try XCTUnwrap(URL(string: "https://attacker.com/checkout/credit-card/return?error_code=1008"))
        XCTAssertFalse(matcher.matches(url))
    }

    // MARK: - parseResult

    func test_parseResult_errorCode1008_returnsCancelled() throws {
        // 1008 is Mollie's documented "Authorisation cancelled by cardholder"
        // — the only code that means user-initiated cancel.
        let url = try XCTUnwrap(URL(string: "https://www.mollie.com/checkout/credit-card/return?error_code=1008"))
        XCTAssertEqual(matcher.parseResult(from: url), .cancelled)
    }

    func test_parseResult_nonCancelErrorCode_returnsFailedWithStableToken() throws {
        // Real ACS decline (or any non-1008 code) must surface as .failed —
        // otherwise merchants can't distinguish "user backed out" from
        // "card rejected", and `mollie_error_<code>` gives DevTools a
        // stable diagnostic token.
        let url = try XCTUnwrap(URL(string: "https://www.mollie.com/checkout/credit-card/return?error_code=1005"))
        XCTAssertEqual(
            matcher.parseResult(from: url),
            .failed(reason: .sdkError(message: "mollie_error_1005"))
        )
    }

    func test_parseResult_missingErrorCode_returnsFailedChallengeFailed() throws {
        // Should be unreachable via matches() (which gates on error_code
        // presence), but the contract has to be defined: no code → no
        // signal → fail closed rather than silently authenticate or cancel.
        let url = try XCTUnwrap(URL(string: "https://www.mollie.com/checkout/credit-card/return"))
        XCTAssertEqual(matcher.parseResult(from: url), .failed(reason: .challengeFailed))
    }
}
