import MollieComponents
import MolliePaymentsUI
import SwiftUI

// MARK: - Integration shape: embedded SwiftUI card form

//
// When you want the card form INLINE in your own checkout layout (rather
// than a modal sheet), drop `MolliePaymentCardFormView` straight into the
// view tree. It renders the SDK card fields and its own "Pay with card"
// button; on any terminal state `onResult` fires exactly once with a
// `MolliePaymentResult`.
//
// Defaults used here:
//   • theme:     omitted → the Mollie-branded default theme.
//   • endpoints omitted → Mollie production, which is the default. A
//                merchant app never overrides this.

struct CardFormExample: View {
    /// STEP 1 — Get a client access token (pasted here; from your backend in
    /// a real app).
    @State private var clientAccessToken = ""

    /// STEP 2 — Hold the result for display once the form completes.
    @State private var result: MolliePaymentResult?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // A bit of checkout-style chrome so the embedded form sits in
                // a realistic surrounding layout.
                VStack(alignment: .leading, spacing: 4) {
                    Text("Your order")
                        .font(.headline)
                    HStack {
                        Text("Demo subscription")
                        Spacer()
                        Text("€0.01")
                            .fontWeight(.semibold)
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }

                TokenInputView(clientAccessToken: $clientAccessToken)

                Divider()

                // STEP 3 — Embed the card form. Keyed on the token so the SDK
                // re-decodes when you paste a different one. The form's own
                // button is the CTA.
                if clientAccessToken.isEmpty {
                    Text("Paste a client access token above to load the card form.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    MolliePaymentCardFormView(
                        clientToken: clientAccessToken
                    ) { paymentResult in
                        // STEP 4 — Handle the terminal result.
                        result = paymentResult
                    }
                    .id(clientAccessToken)
                }

                if let result {
                    Divider()
                    PaymentResultView(result: result)
                }
            }
            .padding()
        }
        .navigationTitle("Card Form")
        .navigationBarTitleDisplayMode(.inline)
    }
}
