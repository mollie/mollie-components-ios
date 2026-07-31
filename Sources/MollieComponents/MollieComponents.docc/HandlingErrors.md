# Handling Errors

Map every outcome the payment sheet can hand back to merchant-facing behavior.

## Overview

Every entry point — ``MollieCheckout``'s `presentCard(from:)` and `makeCardComponent(onResult:)`, and ``MollieCardComponent`` directly — resolves to a single ``MolliePaymentResult`` with three terminal states:

- ``MolliePaymentResult/completed(_:)`` — the payment succeeded; the associated ``MolliePayment`` carries the `sessionToken` you reconcile against your backend.
- ``MolliePaymentResult/failed(_:)`` — the flow ended in a failure, carrying a `MollieError`.
- ``MolliePaymentResult/cancelled`` — the cardholder dismissed the flow.

```swift
switch result {
case .completed(let payment):
    // payment.sessionToken, payment.amount, payment.currency
case .failed(let error):
    // Inspect error and map to your own localized UI (see the table below)
case .cancelled:
    // Normal dismissal — not an error
}
```

### Cancellation is not an error

``MolliePaymentResult/cancelled`` is a **normal terminal state**, distinct from ``MolliePaymentResult/failed(_:)``. It fires when the cardholder dismisses the sheet, taps cancel, or the presenting context is torn down. Do not surface it as an error, log it as a failure, or retry automatically — treat it the way you would a user backing out of any modal. (The underlying `MollieError` cancellation cases listed under [Reserved](#Reserved) are never delivered to you; cancellation always surfaces here.)

> Note: The `errorDescription` strings on `MollieError` are developer- and log-facing copy. They are not localized for cardholders — map each case to your own UI strings using the table below. This is unaffected by the SDK's own localization support: the cardholder-facing chrome the SDK renders itself (the card form and 3-D Secure screen) is localized and follows the `locale` you pass to ``MollieCheckout``'s `init(clientToken:locale:beforeSubmit:)` (default: the device locale), but `MollieError` deliberately stays English so it's safe as log/support copy regardless of the cardholder's locale.

## Merchant-reachable cases

The table below covers every `MollieError` case the SDK can deliver in `.failed`. Case names are shown in code font; the live documentation for each (Option-click in Xcode) lives on the real `MollieError` symbols in the `MollieCore` module.

| Case | Meaning / Cause | Recommended action |
| --- | --- | --- |
| `.network(URLError)` | Transport failure before any HTTP response (offline, DNS, TLS, URL-layer timeout). The SDK auto-retries transient transport failures for idempotent reads (GET/PUT/DELETE) only; charging POSTs (tokenisation, checkout-attempt creation) surface on the first failure with an indeterminate outcome. | Transient. Prompt "check your connection and try again"; inspect `URLError.code` for specifics. Re-presenting starts a fresh attempt — for a charging operation, reconcile server-side first rather than blindly re-charging. |
| `.api(.unauthorized)` (401) | The bearer `clientToken` is missing, expired, or invalid. | Merchant fix: your backend mints a fresh session and hands the new token to the SDK. Not retryable with the same token. |
| `.api(.forbidden)` (403) | Authenticated but not permitted — wrong profile, payment method not enabled, or test/live mode mismatch. | Configuration fix; refreshing the token won't help. Verify the profile and mode. Contact support if entitlements look correct. |
| `.api(.notFound)` (404) | Resource missing: the session expired or never existed, or the base URL/path is wrong. | Confirm the token is current and the ``MollieEndpoints`` are correct; otherwise create a new session. |
| `.api(.validationFailed([Violation]))` (422) | RFC 7807 field violations — usually bad card input (often rewrapped as `.tokenizationFailed`). | Map each `Violation.name` to a form field and show its `reason` inline. Cardholder-retryable. |
| `.api(.conflict(retryAfter:))` (409) | A competing or duplicate operation on the session. | The SDK auto-retries idempotent ops only, honouring `retryAfter` when present; a charging POST surfaces immediately (no auto-retry). On a charging operation, reconcile or create a new session rather than re-charging blindly. |
| `.api(.rateLimited(retryAfter:))` (429) | The request was throttled. | The SDK auto-retries idempotent ops only, honouring `retryAfter` (falling back to jittered exponential backoff); a charging POST surfaces immediately. Don't hard-fail to the cardholder on a 429 from a read — the SDK is already backing off. If it surfaces from a charge, review your call cadence before re-presenting. |
| `.api(.serverError(Int))` | An unexpected HTTP status (the wrapped `Int`, e.g. 500/502/503). | A 5xx is server-classified transient: the SDK auto-retries it with jittered backoff for idempotent ops only. A charging POST is **never** auto-retried on 5xx — the outcome is indeterminate, so it surfaces for server-side reconciliation before any re-charge. An unexpected 4xx is likely an integration issue — contact support with the status code. |
| `.invalidClientToken(reason:)` | The `clientToken` is not valid base64 or its JSON failed to parse. | Integration error: forward the exact `client_access_token` verbatim — no re-encoding or truncation — and confirm it was not already consumed. Not retryable. |
| `.timeout(operation:)` | The polling budget was exhausted, an attempt got stuck, or no terminal event arrived (`operation` is one of session-polling, checkout-attempt-polling, checkout-attempt-stuck, card-payment). Outcome is **indeterminate**. | Reconcile server-side before re-presenting — do not silently re-charge. Surface "we're confirming your payment". The polling budget (`pollingTimeoutSeconds`) is configurable. |
| `.sessionFailed(ProblemDetails?)` | A backend terminal failure, or the SDK rejected an unsafe 3DS challenge or redirect URL (`title: "invalid_configuration"`, `detail: "Unsafe 3DS challenge URL"` / `"Unsafe redirect URL"`). | A genuine decline → read `ProblemDetails.detail`/`.title` and suggest another card. For the "Unsafe … URL" variants → a security/configuration signal; contact support with the session token (the cardholder cannot fix this). |
| `.tokenizationFailed(reason:underlying:)` | Card-to-token conversion failed during tokenisation — a validation rewrap, or another error in `underlying`. | Usually a mistyped card: show `reason` and prompt re-entry. If `underlying` is a network or server error, the tokenisation POST is **not** auto-retried (it is a charging op with no server-honoured dedup) and the outcome may be indeterminate — a re-attempt should follow server-side reconciliation rather than a blind re-charge. (`reason` is safe to display — the SDK never logs PAN or CVC.) |
| `.threeDSFailed(reason:)` | 3D Secure did not succeed. See the `ThreeDSFailureReason` cases below. | Depends on the reason — see the next table. |
| `.invalidConfiguration(field:reason:)` | Misuse or an unsupported host state, split by `field`. `cardNumber`/`expiry`/`cardholderName`/`cvc` are **cardholder-correctable** (show `reason` inline). `host`/`scene`/`sheet`/`submit`/`checkoutAttemptToken` are **integration bugs** (present from a VC in a window, not while another modal is up; require an active foreground scene; no double-submit). `"validator/parser disagreement"` is an SDK bug. | Fix the integration for the host-state fields; show `reason` inline for the card-field ones. Report the "validator/parser disagreement" variant to Mollie. |
| `.unknown(Error)` | Unclassified catch-all — in practice where uncaught `DecodingError`s land. | Allow one retry. If it persists, capture the wrapped description plus request context and contact support. Engineering should monitor `.unknown` rates (spikes ≈ contract drift). |

### 3D Secure failures

When `.threeDSFailed(reason:)` is delivered, the associated `ThreeDSFailureReason` narrows the cause:

| Reason | Meaning / Cause | Recommended action |
| --- | --- | --- |
| `.challengeFailed` | The bank rejected authentication — wrong OTP, the banking app wasn't approved, or the cardholder cancelled the challenge. | Cardholder-retryable, or suggest another card. |
| `.sdkError(message:)` | A WebView or ACS technical failure (`navigation_error_<code>`, `"Unsafe navigation blocked"`, `"timeout"`, `3DS error <code>`, `mollie_error_<code>`). | Mostly transient → retry. `"Unsafe navigation blocked"` is a security signal — contact support. Do not show the raw `message`; map it to a generic "couldn't complete authentication". |

## Reserved

The following cases are **declared but never currently emitted** by the SDK. They exist on the types for forward-compatibility. You do **not** need to write dead `catch`/`switch` arms for them — handling the merchant-reachable cases above plus a `default` is sufficient:

- `MollieError.sessionExpired` — session expiry surfaces as `.api(.notFound)` or `.timeout`, not this case.
- `MollieError.sessionCancelled` — cancellation surfaces as ``MolliePaymentResult/cancelled``.
- `MollieError.userCancelled` — cancellation surfaces as ``MolliePaymentResult/cancelled``.
- `MollieError.decoding(DecodingError)` — decode failures currently fall through to `.unknown`.
- `ThreeDSFailureReason.timeout` — the 3DS timeout path currently uses `.sdkError("timeout")`.
- `ThreeDSFailureReason.unknown` — no current code path constructs it.

> Note: These are reserved as documentation only — there is no associated API change. A future SDK release may begin emitting some of them; until then, treat them as unreachable.

## Supporting payload types

Three supporting types carry the detail you map into merchant UI:

- **`ProblemDetails`** — the RFC 7807 body on `.sessionFailed`. Inspect `type`, `title`, `detail`, `status`, `instance`, and `extensions`. The SDK synthesizes `"invalid_configuration"` (with the "Unsafe … URL" detail) for the URL-safety rejections, and falls back to `"unknown"` when the server body can't be parsed.
- **`Violation`** — one per field error inside `.api(.validationFailed)`. `name` identifies the offending form field; `reason` is display-ready copy you can show inline.
- **`.tokenizationFailed.underlying`** — inspect this wrapped error to tell a validation failure (cardholder mistyped) apart from a network or server failure. Tokenisation is a charging POST, so the SDK does not auto-retry it; on a network/server failure the outcome may be indeterminate, and any re-attempt should follow server-side reconciliation rather than a blind re-charge.
