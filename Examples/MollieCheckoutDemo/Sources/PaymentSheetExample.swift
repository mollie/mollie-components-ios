import MollieComponents
import MolliePaymentsUI
import SwiftUI

// MARK: - Integration shape: SwiftUI payment sheet

//
// The simplest Mollie integration. Attach the `.molliePaymentSheet`
// modifier to any view, flip a `Bool` to present it, and read the typed
// `MolliePaymentResult` in the `onResult` closure. The SDK presents its own
// modal card form from the active scene — you don't manage a sheet or a
// navigation controller yourself.
//
// Defaults used here:
//   • theme:     omitted → the Mollie-branded default theme.
//   • endpoints omitted → Mollie production, which is the default. A
//                merchant app never overrides this.

struct PaymentSheetExample: View {
    /// STEP 1 — Get a client access token. Here it's pasted via
    /// TokenInputView; in your app it comes from your backend.
    @State private var clientAccessToken = ""

    /// STEP 2 — A Bool that drives presentation of the sheet.
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
        // STEP 5 — Attach the SDK sheet. On any terminal state the binding
        // flips back to false and `onResult` fires exactly once.
        .molliePaymentSheet(
            isPresented: $isPresentingSheet,
            clientToken: clientAccessToken
        ) { paymentResult in
            result = paymentResult
        }
    }
}
