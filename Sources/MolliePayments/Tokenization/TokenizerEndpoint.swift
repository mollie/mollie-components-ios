import Foundation
import MollieCore

package enum TokenizerEndpoint {
    /// Charging POST that exchanges the PAN for a card token — **not
    /// auto-retried**.
    ///
    /// Per spike #316 (Model B, token-as-anchor), the PCI tokeniser honours no
    /// inbound idempotency header on `POST /v1/card-tokens`, so the SDK emits
    /// none and never transparently retries it (POST is excluded from
    /// `isIdempotent` in `TokenizerClient`). On an indeterminate failure the
    /// SDK surfaces `.timeout`; the merchant reconciles server-side. In-process
    /// re-taps are guarded by `SingleFlight` in `CardPaymentCoordinator`. See
    /// decisions-log "2026-06-23 — Network idempotency model decided
    /// (spike #316 resolved)".
    package static func tokenize(
        _ data: CardSubmissionData,
        profileToken: String,
        testmode: Bool
    ) -> Endpoint<CardToken> {
        let month = String(format: "%02d", data.expiryMonth)
        let year = String(data.expiryYear).suffix(2)
        return Endpoint(
            path: "v1/card-tokens",
            method: .post,
            body: TokenizeRequest(
                profileToken: profileToken,
                cardHolder: data.cardholderName,
                cardNumber: data.cardNumber,
                cardExpiryDate: "\(month)/\(year)",
                cardCvv: data.cvc,
                testmode: testmode
            ),
            requiresAuth: false,
            headers: [
                TokenisationAgentHeader.headerName:
                    TokenisationAgentHeader.encoded(productVersion: MollieSDKVersion),
            ]
        )
    }
}

// MARK: - Request body

package struct TokenizeRequest: Encodable, Equatable {
    package let profileToken: String
    package let cardHolder: String?
    package let cardNumber: String
    package let cardExpiryDate: String
    package let cardCvv: String
    package let testmode: Bool
}

/// Belt-and-braces: the request struct holds raw PAN, CVV, cardholder name
/// and expiry. Any reflection-based dump (`String(describing:)`,
/// `dump(_:)`, the Swift runtime's default `print` of a struct, third-party
/// crash reporters that auto-mirror locals) would otherwise emit the
/// cleartext fields. Conforming to CustomDebugStringConvertible forces a
/// fixed redacted string regardless of how the struct is rendered.
///
/// The wire path (JSONEncoder) is unaffected — only `debugDescription`
/// callers see the placeholder.
extension TokenizeRequest: CustomDebugStringConvertible {
    package var debugDescription: String {
        "<TokenizeRequest redacted>"
    }
}

// MARK: - Tokenisation-Agent header

/// Identifies the iOS SDK to the PCI tokeniser. Schema mirrors the Java record
/// `TokenisationAgentHeader` server-side. See docs/mvp/modules/02-mollie-payments.md
/// for the contract.
package enum TokenisationAgentHeader {
    package static let headerName = "Tokenisation-Agent"

    package static func encoded(productVersion: String) -> String {
        let payload: [String: Any] = [
            "product": "Mollie-iOS-SDK",
            "productVersion": productVersion,
            "productLocation": "card",
            "parentUri": NSNull(),
            "sourceUri": NSNull(),
            "plugin": NSNull(),
            "pluginVersion": NSNull(),
        ]
        // Payload is a literal [String: Any] of strings + NSNull — JSONSerialization
        // cannot fail on this input shape. A `try?` fallback to "" would silently
        // ship a malformed Tokenisation-Agent header to the backend.
        // swiftlint:disable:next force_try
        let data = try! JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        return data.base64EncodedString()
    }
}
