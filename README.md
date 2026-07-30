# Mollie Components iOS SDK

Native Swift SDK for accepting card payments via Mollie. Drop-in payment UI, theming, and 3D Secure — all in one import.

> **Status:** Pre-1.0, in active development. APIs may change before the 1.0 release.

## Requirements

- iOS 16.0+
- Swift 5.9+
- Xcode 16+

## Installation

### Swift Package Manager

```swift
.package(url: "https://github.com/mollie/mollie-components-ios", from: "0.1.0")
```

Or in Xcode: **File → Add Package Dependencies…** → paste the repo URL.

The SDK is distributed exclusively via Swift Package Manager.

## Quick start

`MollieComponents` is the only library the package exposes — a single `import MollieComponents` gives you `MollieCheckout`, the payment-sheet and card-form surfaces, and every public type you need.

```swift
import MollieComponents

let checkout = try MollieCheckout(clientToken: token)
let result = await checkout.presentCard(from: viewController)

switch result {
case .completed(let payment): break // success
case .failed(let error):      break // handle error
case .cancelled:              break // user dismissed
}
```

## Examples

A runnable sample app lives in [`Examples/MollieCheckoutDemo`](Examples/MollieCheckoutDemo). It demonstrates the modal payment sheet (SwiftUI and UIKit), the embedded card form, and how to wire in a server-issued client access token.

See [`Examples/MollieCheckoutDemo/README.md`](Examples/MollieCheckoutDemo/README.md) for the feature list and run steps.

## Documentation

- [Hosted developer docs](https://mollie.github.io/mollie-components-ios/documentation/molliecomponents/) — the DocC reference published to GitHub Pages on each release
- [`Sources/MollieComponents/MollieComponents.docc`](Sources/MollieComponents/MollieComponents.docc) — DocC catalog (build with `make docs`; Option-click any symbol in Xcode for quick-help)
- [`HandlingErrors`](Sources/MollieComponents/MollieComponents.docc/HandlingErrors.md) — merchant error reference (authoritative error catalog)
- [`docs/policies/VERSIONING.md`](docs/policies/VERSIONING.md) — versioning and SemVer policy
- [`CHANGELOG.md`](CHANGELOG.md) — release history
- [`SECURITY.md`](SECURITY.md) — security model and vulnerability reporting

## Contributing

See [`CONTRIBUTING.md`](CONTRIBUTING.md).

## License

See [`LICENSE`](LICENSE).
