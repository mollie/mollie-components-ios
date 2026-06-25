import MollieComponents
import MolliePaymentsUI
import SwiftUI
import UIKit

// MARK: - Integration shape: UIKit payment sheet

//
// The UIKit mirror of PaymentSheetExample. From any `UIViewController`, call
// the async `MolliePaymentSheet.present(from:clientToken:theme:)` and await
// the typed `MolliePaymentResult`. The SDK presents its modal card form from
// the host view controller you pass in.
//
// Defaults used here:
//   • theme: omitted → the Mollie-branded default theme.
//   • Production endpoints are the default — `present(from:clientToken:)`
//     targets Mollie production. A merchant app never overrides this.
//
// `PaymentSheetUIKitExample` (bottom of this file) is a thin
// `UIViewControllerRepresentable` so the SwiftUI RootView can navigate to
// this UIKit screen.

/// Pure-UIKit example: a paste field, a Pay button, and a result label.
final class PaymentSheetUIKitViewController: UIViewController {
    private let tokenField = UITextField()
    private let payButton = UIButton(type: .system)
    private let resultLabel = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        title = "Payment Sheet (UIKit)"
        layoutUI()
    }

    /// STEP 1 — Get a client access token. This example pastes it into a text
    /// field; your app fetches it from your backend (see TokenInputView's
    /// commented `fetchClientAccessToken` reference).
    private var clientAccessToken: String {
        tokenField.text ?? ""
    }

    /// STEP 2 — On tap, present the sheet and await the result. `present(...)`
    /// is async and returns a single `MolliePaymentResult`.
    @objc private func payTapped() {
        let token = clientAccessToken
        guard !token.isEmpty else { return }

        resultLabel.text = nil
        Task {
            // STEP 3 — Present from `self`. Theme + production endpoints are
            // defaulted.
            let result = await MolliePaymentSheet.present(
                from: self,
                clientToken: token
            )
            // STEP 4 — Branch on the terminal result.
            switch result {
            case let .completed(payment):
                resultLabel.text = "Completed: \(payment.amount) \(payment.currency)"
            case let .failed(error):
                resultLabel.text = "Failed: \(error.localizedDescription)"
            case .cancelled:
                resultLabel.text = "Cancelled"
            }
        }
    }

    // MARK: - Layout (plain UIKit, not part of the SDK integration)

    private func layoutUI() {
        tokenField.placeholder = "Paste a client access token"
        tokenField.borderStyle = .roundedRect
        tokenField.autocorrectionType = .no
        tokenField.autocapitalizationType = .none
        tokenField.font = .monospacedSystemFont(ofSize: 13, weight: .regular)

        payButton.setTitle("Pay", for: .normal)
        payButton.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        payButton.addTarget(self, action: #selector(payTapped), for: .touchUpInside)

        resultLabel.numberOfLines = 0
        resultLabel.font = .preferredFont(forTextStyle: .subheadline)
        resultLabel.textColor = .secondaryLabel

        let hint = UILabel()
        hint.text = "Demo only — paste a token you minted on your server."
        hint.numberOfLines = 0
        hint.font = .preferredFont(forTextStyle: .caption1)
        hint.textColor = .secondaryLabel

        let stack = UIStackView(arrangedSubviews: [tokenField, hint, payButton, resultLabel])
        stack.axis = .vertical
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 24),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
        ])
    }
}

/// SwiftUI wrapper so RootView can navigate to the UIKit example.
struct PaymentSheetUIKitExample: UIViewControllerRepresentable {
    func makeUIViewController(context _: Context) -> PaymentSheetUIKitViewController {
        PaymentSheetUIKitViewController()
    }

    func updateUIViewController(_: PaymentSheetUIKitViewController, context _: Context) {
        // No props to push down — the VC owns its own state.
    }
}
