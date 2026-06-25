import SwiftUI

// MARK: - Integration shape

//
// Some payment methods take the shopper out to a bank/3DS page and then
// return to your app via a custom URL scheme. This sample registers
// `mollie-demo://success` (see Info.plist) as that return URL; the app
// entry point (`MollieCheckoutDemoApp`) listens with `.onOpenURL` and
// presents this screen when the redirect lands.
//
// In your own app, point the redirect at a URL scheme you own and route it
// to whatever "thank you" / order-confirmation screen fits your flow.

/// Minimal confirmation screen shown after a `mollie-demo://success`
/// redirect returns the shopper to the app.
struct CheckoutSuccessView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.green)

            Text("Thank you!")
                .font(.title.bold())

            Text("Your payment was received. You've returned to the app via "
                + "the mollie-demo://success redirect.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button("Done") { dismiss() }
                .buttonStyle(.borderedProminent)
        }
        .padding(32)
    }
}
