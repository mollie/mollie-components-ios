import Foundation
import MollieCore

/// Tiny factory that wraps the V2 `PATCH /sessions/{token}/details` request
/// shape per payment method. Keeps method-specific knowledge in MolliePayments
/// while the transport (`SessionEndpoint.updateDetails`) stays generic in
/// MollieCore.
enum SessionPatchRequest {
    static func creditCard(token: String, fingerprint: DeviceFingerprint) -> UpdateDetailsRequest {
        UpdateDetailsRequest(
            paymentMethodDetails: PaymentMethodDetailsRequest(
                method: "creditcard",
                cardToken: token
            ),
            fingerprint: fingerprint
        )
    }
}
