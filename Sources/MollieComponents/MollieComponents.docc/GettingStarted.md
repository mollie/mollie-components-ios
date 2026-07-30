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

`MollieComponents` is the only library the package exposes — the entire merchant surface is reachable through it alone.

## Build a checkout

``MollieCheckout`` owns the session context for a client access token. The SDK never presents its own sheet — you own presentation, either by pushing the card form modally from a `UIViewController`, or by embedding ``MollieCardComponent`` in your own SwiftUI layout (including your own `.sheet`, if you want a modal).

```swift
import MollieComponents

let checkout = try MollieCheckout(clientToken: clientToken)
```

Construction decodes the token eagerly and throws if it's malformed, so you can fail fast before presenting anything.

## Present modally (UIKit)

Call `presentCard(from:)` with the host view controller and `await` the terminal outcome:

```swift
let result = await checkout.presentCard(from: viewController)

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

The sheet always renders with Mollie's branded appearance — see <doc:Theming>.

## Present inline (SwiftUI)

Vend the embeddable form with `makeCardComponent(onResult:)` and place it in your own layout — including your own `.sheet`, if you want a modal:

```swift
import MollieComponents
import SwiftUI

struct CheckoutScreen: View {
    @State private var isPaying = false
    let clientToken: String

    var body: some View {
        Button("Pay") { isPaying = true }
            .sheet(isPresented: $isPaying) {
                if let checkout = try? MollieCheckout(clientToken: clientToken) {
                    checkout.makeCardComponent { result in
                        switch result {
                        case .completed(let payment): break
                        case .failed(let error): break
                        case .cancelled: break
                        }
                        isPaying = false
                    }
                }
            }
    }
}
```

Or embed the card form directly in your layout with ``MollieCardComponent`` — no modal, the form's own "Pay with card" button is the call to action:

```swift
checkout.makeCardComponent { result in
    // Same MolliePaymentResult, fired exactly once
}
```

## Handle the result

Every entry point resolves to the same ``MolliePaymentResult``:

- ``MolliePaymentResult/completed(_:)`` carries a ``MolliePayment`` with the `sessionToken` you use to reconcile server-side.
- ``MolliePaymentResult/failed(_:)`` carries the failure. Map it to your own localized UI — the full catalog of causes and recommended actions is in <doc:HandlingErrors>.
- ``MolliePaymentResult/cancelled`` means the cardholder dismissed the flow. This is a normal terminal state, **not** an error.

## Next steps

- <doc:Theming> — how the sheet's appearance works.
- <doc:HandlingErrors> — the complete merchant error reference.
