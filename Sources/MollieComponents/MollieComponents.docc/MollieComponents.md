# ``MollieComponents``

Accept card payments in your iOS app with a drop-in, PCI-aware payment UI — card tokenization, 3D Secure, and theming behind a single import.

## Overview

`MollieComponents` is the merchant-facing entry point to the Mollie Components iOS SDK. You present a payment surface — modal or embedded — hand it a server-issued client access token, and receive a single typed ``MolliePaymentResult`` describing how the flow ended. The card number and CVC the cardholder types are captured inside Mollie's own UI and tokenized over TLS; they never cross the documented SDK boundary into your code. Your `onResult` callback receives only session metadata, never raw card data.

3D Secure is handled for you. When the issuer requires a challenge, the SDK presents the authentication WebView, drives it to a terminal state, and folds the outcome back into the same ``MolliePaymentResult`` you already handle — there is no separate 3DS callback to wire up.

> Important: The SDK runs inside your app's process. UIKit provides no platform-level isolation between your code and the SDK, so the protection of typed card data is **contractual, not platform-enforced**. Read `SECURITY.md` at the repository root for the full trust model — what the SDK defends against, what it cannot enforce, and the integration practices your team must follow.

To get going in a few lines, see <doc:GettingStarted>. To restyle the sheet to match your brand, see <doc:Theming>. To map every outcome the SDK can hand back to merchant-facing behavior, see <doc:HandlingErrors>.

## Topics

### Getting Started

- <doc:GettingStarted>
- ``MolliePaymentSheet``

### Presenting

- ``MolliePaymentSheet``
- ``MolliePaymentCardFormView``

### Results

- ``MolliePaymentResult``
- ``MolliePayment``

### Customizing appearance

- <doc:Theming>

### Configuration

- ``MolliePaymentEndpoints``

### Handling Errors

- <doc:HandlingErrors>
