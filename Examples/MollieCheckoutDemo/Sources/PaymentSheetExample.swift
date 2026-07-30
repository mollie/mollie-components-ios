import MollieComponents
import SwiftUI

// MARK: - Integration shape: host-owned sheet + MollieCardComponent

//
// The SDK doesn't present its own sheet — the host wraps `MollieCardComponent`
// in its own `.sheet` modifier. Build a `MollieCheckout` from the client
// token, vend the component via `makeCardComponent(onResult:)`, and read the
// typed `MolliePaymentResult` in the `onResult` closure.
//
// Appearance always renders with the Mollie-branded default theme — there is
// no public way to override it. Endpoints default to Mollie production; a
// merchant app never overrides this.

struct PaymentSheetExample: View {
    /// STEP 1 — Get a client access token. Here it's pasted via
    /// TokenInputView; in your app it comes from your backend.
    @State private var clientAccessToken = ""

    /// STEP 2 — A Bool that drives the host's own sheet.
    @State private var isPresentingSheet = false

    /// STEP 3 — Somewhere to stash the result for display.
    @State private var result: MolliePaymentResult?

    var body: some View {
        Form {
            Section {
                TokenInputView(clientAccessToken: $clientAccessToken)
            }

            Section {
                // STEP 4 — Present the sheet. Disabled until a token exists.
                Button("Pay") {
                    result = nil
                    isPresentingSheet = true
                }
                .disabled(clientAccessToken.isEmpty)
            }

            if let result {
                Section("Result") {
                    PaymentResultView(result: result)
                }
            }
        }
        .navigationTitle("Payment Sheet")
        .navigationBarTitleDisplayMode(.inline)
        // STEP 5 — The host's own sheet. On any terminal state we dismiss it
        // ourselves and `onResult` fires exactly once.
        .sheet(isPresented: $isPresentingSheet) {
            if let checkout = try? MollieCheckout(clientToken: clientAccessToken) {
                NavigationStack {
                    checkout.makeCardComponent { paymentResult in
                        result = paymentResult
                        isPresentingSheet = false
                    }
                    .navigationTitle("Pay with card")
                    .navigationBarTitleDisplayMode(.inline)
                }
            }
        }
    }
}
