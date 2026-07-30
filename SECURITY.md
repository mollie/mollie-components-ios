# Security Model — Mollie Components iOS SDK

## TL;DR

The SDK runs **in your app's process**. Card data the user types into Mollie's UI never crosses the documented SDK boundary (your `onResult` callback receives only session metadata). But UIKit does not provide platform-level isolation between your code and ours, so the security model is **contractual, not platform-enforced**.

This document describes what the SDK does to protect typed card data, what it cannot enforce, and what your team should (and should not) do.

## What the SDK protects

| Defense | Mechanism | Threat covered |
| --- | --- | --- |
| Card-entry fields are **not** in secure-entry mode (by design) | `isSecureTextEntry` is intentionally left `false` on PAN + CVC — card-entry UX requires the user to see the digits they type; masking drives typos and retries that re-expose the PAN more than a screen recorder would. The real screen-capture / observer defenses are the app-switcher + screen-recording privacy overlays, pasteboard + edit-menu (copy / cut / share) blocking, masked accessibility values, and the best-effort field wipe — see the rows below | Documents an intentional non-defense; the covering defenses are listed in the following rows |
| Privacy overlay on app-switcher snapshot | Full-window overlay on `UIApplication.willResignActiveNotification` + `didEnterBackgroundNotification` | iOS app-switcher snapshot captured by the OS |
| Privacy overlay on screen capture / mirroring | Full-window overlay on `UIScreen.capturedDidChangeNotification` | Social-engineered screen sharing, AirPlay |
| Pasteboard action blocking on PAN + CVC | `canPerformAction(_:withSender:)` returns `false` for `copy:`, `cut:`, `_share:`, `_define:`, `_translate:` | Accidental or malicious clipboard scrape (the iOS pasteboard is process-global) |
| Field wipe on submit | `UITextField.text = ""` on PAN + CVC immediately after the form's `onSubmit` fires | Post-submit memory window where the typed PAN sits in the field's storage |
| Field wipe on dismount | Same wipe on `viewWillDisappear` | User navigates away mid-typing or post-result |
| Snapshot value-type wipe | `CardFormSnapshot.zero()` after the host coordinator has consumed the snapshot | The producer-side reference inside the SDK |
| `Tokenisation-Agent` header | Vendor-prefixed identifier on every `/v1/card-tokens` request | Server-side detection of unauthorized SDK usage |
| TLS / SPKI certificate pinning | `MollieEndpoints.production`'s `URLSession` delegate additionally requires the Google Trust Services chain on `sessions.mollie.com` and `api.cc.mollie.com` | A network attacker (rogue CA, compromised device trust store) presenting a certificate from an unrelated issuer |

## TLS / SPKI certificate pinning

Both production API hosts — `sessions.mollie.com` and `api.cc.mollie.com` — sit
behind an additional SPKI (Subject Public Key Info) pin check on top of normal
TLS trust evaluation.

**Additive, not a replacement.** A connection is accepted only if the platform's
own trust evaluation (`SecTrustEvaluateWithError`) passes *and* the validated
chain contains a pinned key. Pinning never rescues a chain the system has
already rejected.

**What's pinned.** The intermediate and both possible roots in the Google Trust
Services chain that issues certificates for both hosts — not the leaf, which
Google rotates roughly every 90 days. Pinning at this tier means routine leaf
renewal needs no SDK update.

**Hard fail, with a safety valve.** If a presented chain passes system trust but
carries none of the pinned keys, the connection is cancelled and the request
surfaces as `MollieError.network`. The pin set also carries an expiry date;
after it passes, pinning silently degrades to system-trust-only so an
unmaintained SDK version doesn't lose all connectivity over a missed rotation.
See [`docs/security/tls-pin-rotation-runbook.md`](docs/security/tls-pin-rotation-runbook.md)
for the rotation and expiry-checkpoint procedure.

**Scope.** Only the two API-client hosts above are pinned. The 3-D Secure
challenge flow renders third-party issuer/ACS pages in a `WKWebView`, which does
not route through the SDK's `URLSession` — so SPKI pinning is not applicable to
that channel. The ACS page is instead defended by an HTTPS-only pre-load guard
that blocks non-HTTPS schemes and private/loopback/link-local/metadata
addresses, an exact-host `postMessage` origin allowlist, and return/cancel URL
matchers host-locked to `secure-3ds.mollie.com`. The residual — a network
attacker holding a device-trusted certificate for the ACS host — is accepted: it
is bounded by browser-grade TLS plus these guards, and Mollie's own Web SDK
applies strictly less here (it loads the ACS with no host validation and gates
`postMessage` on a forgeable body field rather than the sender origin). Own-key
pinning of a third-party ACS host is not possible.

## What the SDK cannot enforce

The embedded form lives in your app's process and view hierarchy. iOS doesn't sandbox views by author. A determined host can:

- Walk `UIApplication.shared.connectedScenes` → window → recursive subviews to find the form's `UITextField` instances and read `.text`.
- Subclass / category-swizzle Mollie types via the Objective-C runtime.
- Read process memory via `mach_vm_read` (requires entitlements not granted to App Store apps; relevant only for jailbroken devices or development builds with `get-task-allow`).
- Inject a third-party keyboard extension that captures every keystroke (mitigated only by the user disabling third-party keyboards).

TLS pinning is pinned at the CA (intermediate + root) tier, not the leaf, because both hosts use Google-managed certificates whose private keys Mollie does not hold. This defends against an unrelated CA issuing a rogue certificate for these hosts, but it does not defend against Google Trust Services itself mis-issuing a certificate for a Mollie host to a third party. That residual is accepted; own-key/leaf pinning would require migrating to self-managed certificates and is not planned.

The SDK does not attempt to detect or block these vectors. They are out of scope for an in-process UI component.

## What your team should and should not do

### ✅ Do

- Use `MollieCardComponent` (embedded SwiftUI) or `MolliePaymentSheet.present(...)` (modal UIKit) — both consume the same hardened form.
- Treat your `onResult` callback as the only source of truth for the payment outcome. The session token + amount + currency it carries are sufficient for backend reconciliation.
- Disable third-party keyboard support in your app's `application(_:shouldAllowExtensionPointIdentifier:)` if your compliance posture demands it. The SDK cannot block keyboards at the field level.
- Audit any custom theme overrides — a malicious theme could leak the typed value via, e.g., a custom `Colors` provider that prints. The default theme is safe.

### ❌ Do not

- Walk the form's view hierarchy to inspect text fields. Even if technically possible, doing so puts your app firmly in PCI **SAQ-D scope**.
- Subclass `MollieCardFormViewController`. The class is `package`-scoped for a reason; subclassing from outside the SDK is unsupported and may break on patch releases.
- Swizzle UIKit selectors on `UITextField` or its `MolliePaymentsUI` subclasses (`CardNumberTextField`, `CVCTextField`, etc.).
- Log the contents of any closure parameter that touches the form. The documented surface (`onResult`) is safe to log; the package-internal `onSubmit` snapshot is not.
- Run the SDK on jailbroken devices in production builds. The platform protections above (privacy overlays, pasteboard isolation) are bypassable on a jailbroken device.

## Stronger isolation when you need it

For merchants whose compliance posture requires platform-enforced isolation:

- **Mollie hosted checkout** (full redirect) — runs in MobileSafari or a hosted `WKWebView`, different process, browser-enforced same-origin policy. PCI SAQ-A.
- **Mollie Web SDK in a WKWebView** — same isolation as a desktop iframe. The iOS SDK ships an opt-in WKWebView-backed embed variant on its roadmap; speak to your account manager if you need it before its public release.
- **Apple Pay** — genuine process isolation via PassKit's XPC service. Already supported as a separate code path; no PAN ever touches your process.

## Reporting

Security issues with the SDK should be reported to **security@mollie.com**. Please do not file them on the public issue tracker.
