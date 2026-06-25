# Security Model — Mollie Components iOS SDK

## TL;DR

The SDK runs **in your app's process**. Card data the user types into Mollie's UI never crosses the documented SDK boundary (your `onResult` callback receives only session metadata). But UIKit does not provide platform-level isolation between your code and ours, so the security model is **contractual, not platform-enforced**.

This document describes what the SDK does to protect typed card data, what it cannot enforce, and what your team should (and should not) do.

## What the SDK protects

| Defense | Mechanism | Threat covered |
| --- | --- | --- |
| Secure input mode on PAN + CVC | `UITextField.isSecureTextEntry = true` | Screen recording, screenshots, AirPlay mirroring, QuickType / dictation caches, VoiceOver value leakage |
| Privacy overlay on app-switcher snapshot | Full-window overlay on `UIApplication.willResignActiveNotification` + `didEnterBackgroundNotification` | iOS app-switcher snapshot captured by the OS |
| Privacy overlay on screen capture / mirroring | Full-window overlay on `UIScreen.capturedDidChangeNotification` | Social-engineered screen sharing, AirPlay |
| Pasteboard action blocking on PAN + CVC | `canPerformAction(_:withSender:)` returns `false` for `copy:`, `cut:`, `_share:`, `_define:`, `_translate:` | Accidental or malicious clipboard scrape (the iOS pasteboard is process-global) |
| Field wipe on submit | `UITextField.text = ""` on PAN + CVC immediately after the form's `onSubmit` fires | Post-submit memory window where the typed PAN sits in the field's storage |
| Field wipe on dismount | Same wipe on `viewWillDisappear` | User navigates away mid-typing or post-result |
| Snapshot value-type wipe | `CardFormSnapshot.zero()` after the host coordinator has consumed the snapshot | The producer-side reference inside the SDK |
| `Tokenisation-Agent` header | Vendor-prefixed identifier on every `/v1/card-tokens` request | Server-side detection of unauthorized SDK usage |
| Endpoint pinning | `MolliePaymentEndpoints.production` hard-codes Mollie's production tokeniser and Sessions Service hosts | Misrouted traffic if a merchant override misconfigures URLs |

## What the SDK cannot enforce

The embedded form lives in your app's process and view hierarchy. iOS doesn't sandbox views by author. A determined host can:

- Walk `UIApplication.shared.connectedScenes` → window → recursive subviews to find the form's `UITextField` instances and read `.text`.
- Subclass / category-swizzle Mollie types via the Objective-C runtime.
- Read process memory via `mach_vm_read` (requires entitlements not granted to App Store apps; relevant only for jailbroken devices or development builds with `get-task-allow`).
- Inject a third-party keyboard extension that captures every keystroke (mitigated only by the user disabling third-party keyboards).

The SDK does not attempt to detect or block these vectors. They are out of scope for an in-process UI component.

## What your team should and should not do

### ✅ Do

- Use `MolliePaymentCardFormView` (embedded SwiftUI) or `MolliePaymentSheet.present(...)` (modal UIKit) — both consume the same hardened form.
- Treat your `onResult` callback as the only source of truth for the payment outcome. The session token + amount + currency it carries are sufficient for backend reconciliation.
- Disable third-party keyboard support in your app's `application(_:shouldAllowExtensionPointIdentifier:)` if your compliance posture demands it. The SDK cannot block keyboards at the field level.
- Audit any custom theme overrides — a malicious theme could leak the typed value via, e.g., a custom `Colors` provider that prints. The default theme is safe.

### ❌ Do not

- Walk the form's view hierarchy to inspect text fields. Even if technically possible, doing so puts your app firmly in PCI **SAQ-D scope**.
- Subclass `MollieCardFormViewController`. The class is `package`-scoped for a reason; subclassing from outside the SDK is unsupported and may break on patch releases.
- Swizzle UIKit selectors on `UITextField` or its `MolliePaymentsUI` subclasses (`CardNumberTextField`, `CVCTextField`, etc.).
- Log the contents of any closure parameter that touches the form. The documented surface (`onResult`) is safe to log; the package-internal `onSubmit` snapshot is not.
- Run the SDK on jailbroken devices in production builds. The platform protections above (secure input mode, pasteboard isolation) are bypassable on a jailbroken device.

## Stronger isolation when you need it

For merchants whose compliance posture requires platform-enforced isolation:

- **Mollie hosted checkout** (full redirect) — runs in MobileSafari or a hosted `WKWebView`, different process, browser-enforced same-origin policy. PCI SAQ-A.
- **Mollie Web SDK in a WKWebView** — same isolation as a desktop iframe. The iOS SDK ships an opt-in WKWebView-backed embed variant on its roadmap; speak to your account manager if you need it before its public release.
- **Apple Pay** — genuine process isolation via PassKit's XPC service. Already supported as a separate code path; no PAN ever touches your process.

## Reporting

Security issues with the SDK should be reported to **security@mollie.com**. Please do not file them on the public issue tracker.
