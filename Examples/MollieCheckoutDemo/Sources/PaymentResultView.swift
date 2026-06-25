import MollieComponents
import SwiftUI

// MARK: - Integration shape

//
// Every Mollie surface (the sheet, the embedded card form) reports its
// outcome as a single `MolliePaymentResult` with three terminal cases:
//
//   • .completed(payment) — the payment succeeded. `payment` carries the
//     session token + amount you reconcile against your backend.
//   • .failed(error)      — the payment did not complete. `error` conforms
//     to `LocalizedError`, so `localizedDescription` is display-ready copy.
//   • .cancelled          — the shopper dismissed the flow.
//
// This view renders the result; copy the `switch` into your own app and
// branch however your UX needs (route to a receipt, show a retry, etc.).

/// Renders a `MolliePaymentResult` once an example flow finishes.
struct PaymentResultView: View {
    let result: MolliePaymentResult

    var body: some View {
        switch result {
        case let .completed(payment):
            // The shopper paid. Reconcile `payment.sessionToken` with your
            // backend before you fulfil the order.
            VStack(alignment: .leading, spacing: 8) {
                Label("Payment completed", systemImage: "checkmark.circle.fill")
                    .font(.headline)
                    .foregroundStyle(.green)
                Text("Amount: \(payment.amount) \(payment.currency)")
                    .font(.subheadline)
                Text("Session token: \(payment.sessionToken)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

        case let .failed(error):
            // The payment failed. `error.localizedDescription` is
            // developer/log copy — map the case to your own localized UI.
            VStack(alignment: .leading, spacing: 8) {
                Label("Payment failed", systemImage: "xmark.circle.fill")
                    .font(.headline)
                    .foregroundStyle(.red)
                Text(error.localizedDescription)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

        case .cancelled:
            // The shopper backed out. Usually a no-op — leave them on the
            // checkout screen so they can try again.
            Label("Payment cancelled", systemImage: "minus.circle.fill")
                .font(.headline)
                .foregroundStyle(.secondary)
        }
    }
}
