import Foundation
import MollieCore

/// Builds `CreateCheckoutAttemptRequest` values for each payment method.
/// Mirrors the equivalent checkout-attempt payload builder in the web integration.
///
/// Access narrowed from `public` to `package`: this is an internal seam for
/// `CardPaymentCoordinator` and should not be part of the merchant-facing API.
package enum CreateCheckoutAttemptRequestFactory {
    package static func creditCard(
        pspToken: String,
        fingerprint: DeviceFingerprint
    ) -> CreateCheckoutAttemptRequest {
        CreateCheckoutAttemptRequest(
            paymentMethod: "creditcard",
            checkoutMethod: "card",
            fingerprint: fingerprint,
            pspToken: pspToken,
            wallet: nil,
            walletToken: nil
        )
    }
}
