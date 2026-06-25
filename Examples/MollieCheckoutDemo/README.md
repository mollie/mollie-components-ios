# Mollie Checkout Demo

A small sample app that shows how to accept card payments with the Mollie Components iOS SDK from a merchant app. It links only the public SDK products a merchant needs (`MollieComponents` and `MolliePaymentsUI`) and walks through the common integration shapes — a modal payment sheet, an embedded card form, the UIKit entry point, and how to wire in a server-issued client access token.

Each example screen is written to be read on its own: open the file, follow the numbered `STEP` comments, and copy the pattern into your own checkout.

## Features

- **Modal payment sheet (SwiftUI)** — present the SDK card form as a sheet with the `.molliePaymentSheet` modifier.
- **Embedded card form (SwiftUI)** — drop `MolliePaymentCardFormView` inline into your own checkout layout.
- **Modal payment sheet (UIKit)** — present the sheet from a `UIViewController` with `MolliePaymentSheet.present(from:)`.
- **Paste-token flow** — try every flow end-to-end without standing up a backend by pasting a client access token you generated elsewhere.
- **Result + deep-link handling** — render the typed `MolliePaymentResult` and route a return-URL redirect to a success screen.

## Screenshot

![Demo app menu](docs/screenshot-placeholder.png)

> **Placeholder.** This image path does not exist yet — replace it with a real screenshot of the running app.

## To run

1. Open `Examples/MollieCheckoutDemo/MollieCheckoutDemo.xcodeproj` in Xcode 16+.
2. Get a `clientAccessToken` (see [Getting a token](#getting-a-token) below). **The SDK never mints sessions on-device** — the token comes from your server.
3. Run the app on an iOS 16+ simulator and pick an example from the menu.
4. Paste the token, start the flow, and complete a payment to see the result.

## Getting a token

In production your backend holds the Mollie API key, creates a payment session, and returns only the `clientAccessToken` to the app. To try the demo without standing up a backend, a helper script does that one server call for you — **on your machine, so the API key never touches the app**:

```sh
# from the repository root
make mint-demo-token API_KEY=test_xxxxxxxx
```

It prints a `clientAccessToken`; copy it into the token field in the app. The script accepts optional overrides (`AMOUNT`, `CURRENCY`, `DESCRIPTION`, `REDIRECT_URL`, `SEQUENCE_TYPE`, `CUSTOMER_ID`) — see `Tools/mint-demo-token.sh`.

That script is exactly the call your own server makes (`POST /v2/sessions` with your API key); it lives outside the app on purpose. Never embed a Mollie API key in a shipping app — anyone can extract it from the binary. `Tools/mint-demo-token.sh` and the commented fetch in `Sources/TokenInputView.swift` both show the boundary your real backend implements.

## File → integration-shape map

| File | Integration shape |
|------|-------------------|
| `Sources/MollieCheckoutDemoApp.swift` | App entry point — links the public SDK products and routes the return-URL redirect to the success screen. |
| `Sources/RootView.swift` | Root menu that navigates to each example. |
| `Sources/PaymentSheetExample.swift` | SwiftUI modal payment sheet via the `.molliePaymentSheet` modifier. |
| `Sources/CardFormExample.swift` | Embedded SwiftUI card form via `MolliePaymentCardFormView`. |
| `Sources/PaymentSheetUIKitExample.swift` | UIKit modal payment sheet via `MolliePaymentSheet.present(from:)`. |
| `Sources/TokenInputView.swift` | Where to wire your server-issued `clientAccessToken` (paste field for the demo; backend fetch reference in the comments). |
| `Sources/PaymentResultView.swift` | Renders the typed `MolliePaymentResult` (`.completed` / `.failed` / `.cancelled`). |
| `Sources/CheckoutSuccessView.swift` | Success screen reached via a return-URL redirect (deep-link handling). |
