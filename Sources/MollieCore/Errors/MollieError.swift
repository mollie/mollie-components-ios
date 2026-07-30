import Foundation

/// The error surfaced to merchants when a payment does not complete
/// successfully — carried by `MolliePaymentResult.failed`.
///
/// `errorDescription` strings are developer/log copy; merchants map each
/// case to their own localized UI. Cancellation is **not** modelled here:
/// it surfaces as the non-error terminal state
/// `MolliePaymentResult.cancelled`.
///
/// Each case below documents its cause and recommended remediation.
public enum MollieError: Error {
    /// Transport failure before any HTTP response was received — offline,
    /// DNS, TLS, or a URL-layer timeout.
    ///
    /// The SDK auto-retries transient transport failures for idempotent reads
    /// only (GET/PUT/DELETE); this case surfaces once those retries are
    /// exhausted. Charging POSTs (card tokenisation, checkout-attempt
    /// creation) are **never** auto-retried — they surface on the first
    /// transport failure, since the outcome is indeterminate and no
    /// server-honoured dedup exists (Model B).
    ///
    /// > Tip: Transient. Prompt the cardholder to check their connection
    /// > and try again; inspect `URLError.code` for the specifics.
    /// > Re-presenting the sheet starts a fresh attempt — for a charging
    /// > operation, reconcile server-side first rather than blindly re-charging.
    ///
    /// - Parameter error: The underlying `URLError` from the transport layer.
    case network(URLError)

    /// An HTTP error response from a Mollie service. See `APIError` for the
    /// per-status cause and remediation.
    ///
    /// - Parameter error: The classified API error.
    case api(APIError)

    /// A response body could not be decoded into the expected model.
    ///
    /// > Note: Reserved — not currently emitted. Decode failures fall
    /// > through to `unknown(_:)` in practice, so merchants need not write
    /// > a dedicated `catch`/`switch` arm for this case.
    ///
    /// - Parameter error: The underlying `DecodingError`.
    case decoding(DecodingError)

    /// The `clientToken` is not valid base64, or its decoded JSON could not
    /// be parsed.
    ///
    /// > Important: Integration error. Forward the exact
    /// > `client_access_token` verbatim — do not re-encode, truncate, or
    /// > reuse a token that was already consumed. Not retryable with the
    /// > same token.
    ///
    /// - Parameter reason: A developer-facing description of why the token
    ///   was rejected.
    case invalidClientToken(reason: String)

    /// A polling budget was exhausted, an attempt stalled, or no terminal
    /// event arrived. `operation` is one of `session-polling`,
    /// `checkout-attempt-polling`, `checkout-attempt-stuck`, or
    /// `card-payment`.
    ///
    /// > Important: The payment outcome is **indeterminate**. Reconcile
    /// > server-side before re-presenting — do not silently re-charge.
    /// > Surface a "confirming your payment" state to the cardholder. The
    /// > polling budget is configurable via `pollingTimeoutSeconds`.
    ///
    /// - Parameter operation: The operation whose timeout elapsed.
    case timeout(operation: String)

    /// The payment session has expired.
    ///
    /// > Note: Reserved — not currently emitted. Merchants need not write a
    /// > dedicated `catch`/`switch` arm for this case.
    case sessionExpired

    /// The backend reported a terminal session failure, or the SDK rejected
    /// an unsafe 3DS challenge or redirect URL.
    ///
    /// A genuine decline carries `ProblemDetails` describing the reason. The
    /// SDK synthesizes a `ProblemDetails` with `title: "invalid_configuration"`
    /// and `detail: "Unsafe 3DS challenge URL"` (or `"Unsafe redirect URL"`)
    /// when it blocks an unsafe URL.
    ///
    /// > Important: For a genuine decline, read `ProblemDetails.detail` /
    /// > `.title` and suggest another card. For the "Unsafe … URL" variants
    /// > this is a security/config signal the cardholder cannot fix —
    /// > contact support with the session token.
    ///
    /// - Parameter problem: The RFC 7807 problem details, when available.
    case sessionFailed(ProblemDetails?)

    /// The payment session was cancelled.
    ///
    /// > Note: Reserved — not currently emitted. Cancellation surfaces as
    /// > `MolliePaymentResult.cancelled`, so merchants need not write a
    /// > dedicated `catch`/`switch` arm for this case.
    case sessionCancelled

    /// Converting card details to a token failed during tokenisation —
    /// either a validation failure rewrapped here, or another error carried
    /// in `underlying`.
    ///
    /// > Important: Usually a mistyped card. Show `reason` and prompt
    /// > re-entry. If `underlying` is a network or server error the
    /// > tokenisation POST is **not** auto-retried (it is a charging op with
    /// > no server-honoured dedup); the outcome may be indeterminate, so a
    /// > merchant re-attempt should follow server-side reconciliation rather
    /// > than blindly re-charging. `reason` is PCI-safe: the SDK never logs
    /// > the PAN or CVC.
    ///
    /// - Parameters:
    ///   - reason: A PCI-safe, developer-facing failure description.
    ///   - underlying: The originating error (e.g. network/server), when
    ///     the failure was not a card-input validation problem.
    case tokenizationFailed(reason: String, underlying: Error?)

    /// 3-D Secure authentication did not succeed. See `ThreeDSFailureReason`
    /// for the specific cause and remediation.
    ///
    /// - Parameter reason: The 3DS failure reason.
    case threeDSFailed(reason: ThreeDSFailureReason)

    /// The user cancelled the operation.
    ///
    /// > Note: Reserved — not currently emitted. Cancellation surfaces as
    /// > `MolliePaymentResult.cancelled`, so merchants need not write a
    /// > dedicated `catch`/`switch` arm for this case.
    case userCancelled

    /// The SDK was misused, or the host was in an unsupported state.
    ///
    /// Split by `field`: `cardNumber`, `expiry`, `cardholderName`, and `cvc`
    /// are **cardholder-correctable** — show `reason` inline. `host`, `scene`,
    /// `sheet`, `submit`, and `checkoutAttemptToken` are **integration
    /// bugs** (present from a view controller in a window, not while another
    /// modal is up, from an active foreground scene, with no double-submit).
    /// `"validator/parser disagreement"` is an SDK bug — report it.
    ///
    /// > Important: For the cardholder-correctable fields, surface `reason`
    /// > inline on the form. For the integration fields, fix the call site —
    /// > refreshing tokens or retrying will not help.
    ///
    /// - Parameters:
    ///   - field: The configuration field or host invariant that was invalid.
    ///   - reason: A developer-facing description of the problem.
    case invalidConfiguration(field: String, reason: String)

    /// An unclassified error — the catch-all where otherwise-uncaught
    /// errors (in practice, `DecodingError`s) land.
    ///
    /// > Tip: Allow one retry. If it persists, capture the wrapped error's
    /// > description plus request context and contact support. Engineering
    /// > should monitor `unknown` rates — spikes usually indicate API
    /// > contract drift.
    ///
    /// - Parameter error: The wrapped underlying error.
    case unknown(Error)

    /// An HTTP error response from a Mollie service, classified by status.
    public enum APIError: Equatable {
        /// `401` — the bearer `clientAccessToken` is missing, expired, or
        /// invalid.
        ///
        /// > Important: Merchant fix — your backend mints a fresh session
        /// > and hands the SDK the new token. Not retryable with the same
        /// > token.
        case unauthorized

        /// `403` — authenticated but not permitted: wrong profile, the
        /// method is not enabled, or a test/live mode mismatch.
        ///
        /// > Important: A configuration fix; refreshing the token will not
        /// > help. Verify the profile and mode. Contact support if the
        /// > entitlements look correct.
        case forbidden

        /// `404` — the resource is missing: the session expired or never
        /// existed, or the base URL/path is wrong.
        ///
        /// > Important: Confirm the token is current and the
        /// > `MollieEndpoints` are correct; otherwise create a new
        /// > session.
        case notFound

        /// `422` — RFC 7807 field-level violations, usually bad card input
        /// (often rewrapped as `tokenizationFailed`).
        ///
        /// > Tip: Map each `Violation.name` to a form field and show its
        /// > `reason` inline. Cardholder-retryable.
        ///
        /// - Parameter violations: The reported field violations.
        case validationFailed([Violation])

        /// `409` — a competing or duplicate operation on the session.
        ///
        /// The SDK auto-retries this for idempotent ops only, honouring
        /// `retryAfter` when present. On a charging POST it surfaces
        /// immediately (no auto-retry).
        ///
        /// > Tip: If you see this on a charging operation, reconcile or
        /// > create a new session rather than re-charging blindly.
        ///
        /// - Parameter retryAfter: Seconds the SDK waits before its own retry
        ///   of an idempotent op, from the `Retry-After` header, when provided.
        case conflict(retryAfter: Int?)

        /// `429` — the request was throttled.
        ///
        /// The SDK auto-retries this for idempotent ops only, honouring
        /// `retryAfter` (falling back to jittered exponential backoff). A
        /// charging POST surfaces immediately.
        ///
        /// > Tip: Do not hard-fail to the cardholder on a `429` from a read;
        /// > the SDK is already backing off. If it surfaces from a charge,
        /// > review your call cadence before re-presenting.
        ///
        /// - Parameter retryAfter: Seconds the SDK waits before its own retry
        ///   of an idempotent op, from the `Retry-After` header, when provided.
        case rateLimited(retryAfter: Int?)

        /// An unexpected status code (e.g. `500`, `502`, `503`), carrying
        /// the wrapped code.
        ///
        /// A `5xx` is server-classified transient: the SDK auto-retries it
        /// with jittered backoff for idempotent ops only. A charging POST is
        /// **never** auto-retried on `5xx` — the outcome is indeterminate, so
        /// it surfaces for server-side reconciliation before any re-charge
        /// (Model B). An unexpected `4xx` is likely an integration
        /// issue — contact support with the code.
        ///
        /// - Parameter code: The HTTP status code that was returned.
        case serverError(Int)
    }
}

extension MollieError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .network(error):
            "Network error: \(error.localizedDescription)"
        case let .api(error):
            error.errorDescription ?? "API error."
        case let .decoding(error):
            "Decoding error: \(error.localizedDescription)"
        case let .invalidClientToken(reason):
            "Invalid client access token: \(reason)"
        case let .timeout(operation):
            "Operation timed out: \(operation)"
        case .sessionExpired:
            "The session has expired."
        case let .sessionFailed(problem):
            problem?.detail.map { "Session failed: \($0)" }
                ?? problem?.title.map { "Session failed: \($0)" }
                ?? "Session failed."
        case .sessionCancelled:
            "The session was cancelled."
        case let .tokenizationFailed(reason, _):
            "Card tokenization failed: \(reason)"
        case let .threeDSFailed(reason):
            reason.errorDescription
        case .userCancelled:
            "The user cancelled the operation."
        case let .invalidConfiguration(field, reason):
            "Invalid configuration for \(field): \(reason)"
        case let .unknown(error):
            "Unexpected error: \(error.localizedDescription)"
        }
    }
}

extension MollieError.APIError {
    var errorDescription: String? {
        switch self {
        case .unauthorized:
            return "Authentication failed. Check your client access token."
        case .forbidden:
            return "Access denied."
        case .notFound:
            return "The requested resource was not found."
        case let .validationFailed(violations):
            let detail = violations.map { "\($0.name): \($0.reason)" }.joined(separator: ", ")
            return detail.isEmpty ? "Validation failed." : "Validation failed: \(detail)"
        case let .conflict(retryAfter):
            if let seconds = retryAfter {
                return "Request conflict. Retry after \(seconds) second(s)."
            }
            return "Request conflict."
        case let .rateLimited(retryAfter):
            if let seconds = retryAfter {
                return "Rate limited. Retry after \(seconds) second(s)."
            }
            return "Rate limited. Please try again later."
        case let .serverError(code):
            return "Server error (\(code)). Please try again later."
        }
    }
}

extension ThreeDSFailureReason {
    var errorDescription: String {
        switch self {
        case .challengeFailed:
            "3-D Secure challenge failed."
        case .timeout:
            "3-D Secure authentication timed out."
        case let .sdkError(message):
            "3-D Secure SDK error: \(message)"
        case let .unknown(code, message):
            if let code {
                "3-D Secure error (\(code)): \(message)"
            } else {
                "3-D Secure error: \(message)"
            }
        }
    }
}
