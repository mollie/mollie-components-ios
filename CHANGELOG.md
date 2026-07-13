# Changelog

All notable changes to the Mollie iOS SDK are recorded here.

Format: [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/). Versioning: [SemVer 2.0.0](https://semver.org/), per [VERSIONING.md](docs/policies/VERSIONING.md). Deprecations follow [DEPRECATION.md](docs/policies/DEPRECATION.md).

Each release section uses these headings, in this order, omitting any that do not apply:

- `### Added` — new public APIs or behaviour.
- `### Changed` — backwards-compatible changes to existing public APIs or behaviour.
- `### Deprecated` — public APIs marked deprecated in this release. Each entry names the replacement and the earliest removal version.
- `### Removed` — public APIs removed in this release. Only appears in MAJOR releases.
- `### Fixed` — bug fixes.
- `### Security` — security fixes. Always called out, even if also a bug fix.

## [Unreleased]

### Added

- `PrivacyInfo.xcprivacy` manifest in all four shipped library targets (`MollieCore`, `MolliePayments`, `MolliePaymentsUI`, `MollieComponents`). Declares `PaymentInfo` and `Name` collection for App Functionality, with `NSPrivacyTracking` set to `false` and zero Required Reason API usage in release code.
- Versioning, deprecation, and changelog policies under `docs/policies/`.

### Fixed

- `LICENSE` copyright line corrected from project-template residue to `Copyright (c) 2026 Mollie B.V.`.

### Security

- SPKI certificate pinning on `MolliePaymentEndpoints.production`'s `URLSession` for `sessions.mollie.com` and `api.cc.mollie.com`, additive to system TLS trust. See [SECURITY.md](SECURITY.md#tls--spki-certificate-pinning) and the [rotation runbook](docs/security/tls-pin-rotation-runbook.md).

## [0.0.1] — Pre-GA

Pre-1.0 development. The public API surface is not yet frozen — see [VERSIONING.md](docs/policies/VERSIONING.md) for the pre-1.0 caveat. Notable work shipped under this version range:

### Added

- End-to-end card payment flow: card form (SwiftUI + UIKit), PCI tokenisation against `api.cc.mollie.com/v1/card-tokens`, 3D Secure via WKWebView, session polling to terminal state.
- Four public integration entry points across `MollieCore`, `MolliePayments`, `MolliePaymentsUI`, `MollieComponents`.
- Theming hooks: corner radius, field border, brand-aligned colours.
- In-process security hardening: PAN/CVC copy/cut/share blocking, field wipe on submit and backgrounding, screen-recording privacy overlay, masked VoiceOver values.
- Distribution wiring for Swift Package Manager.
