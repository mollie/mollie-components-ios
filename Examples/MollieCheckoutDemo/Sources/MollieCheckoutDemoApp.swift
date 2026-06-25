import MollieComponents
import MolliePaymentsUI
import SwiftUI

/// Entry point for the Mollie checkout sample app.
///
/// This is a minimal reference sample showing how to integrate the
/// Mollie Components SDK from a merchant app. It links only the two public
/// SDK products a merchant needs:
///
/// - `MollieComponents` — the payment-sheet and card-form surfaces plus
///   the ``MolliePaymentResult`` type.
/// - `MolliePaymentsUI` — the ``MolliePaymentTheme`` used to brand them.
///
/// A real merchant obtains a `clientAccessToken` from their own backend
/// (which in turn calls Mollie). The example screens accept a pasted token
/// so you can try the flows without standing up a server.
@main
struct MollieCheckoutDemoApp: App {
    /// Drives navigation to the success screen when the SDK returns to the
    /// app via the `mollie-demo://success` redirect.
    @State private var showSuccess = false

    var body: some Scene {
        WindowGroup {
            RootView()
                .onOpenURL { url in
                    // The example screens register `mollie-demo://success`
                    // as the merchant return URL. When the SDK reopens the
                    // app on that URL, route to the success screen.
                    if url.scheme == "mollie-demo", url.host == "success" {
                        showSuccess = true
                    }
                }
                .sheet(isPresented: $showSuccess) {
                    // Forward reference: CheckoutSuccessView is authored in
                    // the next task (2b).
                    CheckoutSuccessView()
                }
        }
    }
}
