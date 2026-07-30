# Theming

The payment sheet always renders with Mollie's branded appearance.

## Overview

There is no public API to customize colors, typography, or corner radius. Every entry point — ``MollieCheckout``'s `presentCard(from:)` and `makeCardComponent(onResult:)`, and ``MollieCardComponent`` directly — always renders with the same Mollie-branded default theme.

```swift
let checkout = try MollieCheckout(clientToken: clientToken)
let result = await checkout.presentCard(from: viewController)
```

This is intentional: it keeps the payment surface's visual trust signals consistent across merchant integrations. If your integration needs a different look, embed ``MollieCardComponent`` inside your own layout and style the surrounding chrome — the form itself is not restylable.
