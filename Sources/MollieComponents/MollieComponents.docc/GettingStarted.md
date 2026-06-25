# Getting Started

Add the SDK, present a payment surface, and handle the result.

## Overview

Integrating Mollie Components is three steps: add the package, present the sheet from your checkout screen with a server-issued client access token, and switch over the typed ``MolliePaymentResult`` you get back. Card data the cardholder types stays inside Mollie's UI and is tokenized over TLS — your code only ever sees session metadata.

> Note: The SDK requires iOS 16.0+, Swift 5.9+, and Xcode 16+. It is distributed exclusively via Swift Package Manager.

## Add the package

In your `Package.swift`:

```swift
.package(url: "https://github.com/mollie/mollie-components-ios", from: "0.1.0")
```

Or in Xcode: **File → Add Package Dependencies…**, then paste the repository URL.

Merchants import only the umbrella module:

```swift
import MollieComponents
```

The sub-modules (`MollieCore`, `MolliePayments`, `MolliePaymentsUI`) are available for advanced integrations, but the entire merchant surface is reachable through `MollieComponents` alone.

## Present the sheet (UIKit)

``MolliePaymentSheet`` exposes a single static, `async` entry point. Pass the view controller to present from and the client access token your backend minted for this session; `await` the terminal outcome:

```swift
import MollieComponents

let result = await MolliePaymentSheet.present(
    from: viewController,
    clientToken: clientToken
)

switch result {
case .completed(let payment):
    // Success — reconcile against your backend using payment.sessionToken
    break
case .failed(let error):
    // Map the error to merchant-facing UI — see <doc:HandlingErrors>
    break
case .cancelled:
    // The cardholder dismissed the sheet — not an error
    break
}
```

The `theme` parameter is optional and defaults to Mollie branding. To restyle the sheet, pass a custom theme — see <doc:Theming>.

## Present inline (SwiftUI)

For SwiftUI hosts you have two options. Use the `molliePaymentSheet(isPresented:clientToken:theme:endpoints:onResult:)` modifier to drive a modal from a `Bool` binding:

```swift
import MollieComponents
import SwiftUI

struct CheckoutScreen: View {
    @State private var isPaying = false
    let clientToken: String

    var body: some View {
        Button("Pay") { isPaying = true }
            .molliePaymentSheet(isPresented: $isPaying, clientToken: clientToken) { result in
                switch result {
                case .completed(let payment): break
                case .failed(let error): break
                case .cancelled: break
                }
            }
    }
}
```

Or embed the card form directly in your layout with ``MolliePaymentCardFormView`` — no modal, the form's own "Pay with card" button is the call to action:

```swift
MolliePaymentCardFormView(clientToken: clientToken) { result in
    // Same MolliePaymentResult, fired exactly once
}
```

## Handle the result

Every entry point resolves to the same ``MolliePaymentResult``:

- ``MolliePaymentResult/completed(_:)`` carries a ``MolliePayment`` with the `sessionToken` you use to reconcile server-side.
- ``MolliePaymentResult/failed(_:)`` carries the failure. Map it to your own localized UI — the full catalog of causes and recommended actions is in <doc:HandlingErrors>.
- ``MolliePaymentResult/cancelled`` means the cardholder dismissed the flow. This is a normal terminal state, **not** an error.

## Next steps

- <doc:Theming> — restyle the sheet to match your brand.
- <doc:HandlingErrors> — the complete merchant error reference.
