import SwiftUI

/// The example flows the sample app can demonstrate.
///
/// Each case is one row in the root menu and navigates to the matching
/// example screen. The screens themselves are authored in the next task
/// (2b) — the destinations below are forward references until then.
enum Example: String, CaseIterable, Identifiable {
    case paymentSheetSwiftUI
    case cardFormSwiftUI
    case paymentSheetUIKit

    var id: String {
        rawValue
    }

    /// The merchant-facing row title.
    var title: String {
        switch self {
        case .paymentSheetSwiftUI: "Payment Sheet (SwiftUI)"
        case .cardFormSwiftUI: "Card Form (SwiftUI)"
        case .paymentSheetUIKit: "Payment Sheet (UIKit)"
        }
    }

    /// A one-line description of what the example shows.
    var subtitle: String {
        switch self {
        case .paymentSheetSwiftUI:
            "Present the SDK sheet with the .molliePaymentSheet modifier."
        case .cardFormSwiftUI:
            "Embed MolliePaymentCardFormView inline in a SwiftUI layout."
        case .paymentSheetUIKit:
            "Present the sheet from a UIViewController."
        }
    }
}

/// Root menu for the sample app.
///
/// A plain `NavigationStack` listing the available examples. This is a
/// functional reference sample — deliberately unstyled so the focus
/// stays on the SDK integration.
struct RootView: View {
    var body: some View {
        NavigationStack {
            List {
                Section("Examples") {
                    ForEach(Example.allCases) { example in
                        NavigationLink {
                            destination(for: example)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(example.title)
                                    .font(.headline)
                                Text(example.subtitle)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
            .navigationTitle("Mollie Checkout")
        }
    }

    /// Maps an example to its screen.
    ///
    /// The destination views are authored in the next task (2b); these are
    /// forward references and will not compile until those files land.
    @ViewBuilder
    private func destination(for example: Example) -> some View {
        switch example {
        case .paymentSheetSwiftUI:
            PaymentSheetExample()
        case .cardFormSwiftUI:
            CardFormExample()
        case .paymentSheetUIKit:
            PaymentSheetUIKitExample()
        }
    }
}
