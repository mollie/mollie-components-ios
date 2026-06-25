/// Why a 3-D Secure authentication did not succeed — carried by
/// `MollieError.threeDSFailed(reason:)`.
public enum ThreeDSFailureReason: Sendable, Equatable {
    /// The bank rejected the authentication — wrong OTP, the banking app
    /// was not approved, or the cardholder cancelled the challenge.
    ///
    /// > Tip: Cardholder-retryable. Let them try again, or suggest another
    /// > card.
    case challengeFailed

    /// The 3DS challenge timed out.
    ///
    /// > Note: Reserved — not currently emitted. The timeout path surfaces
    /// > as `sdkError(message: "timeout")` instead, so merchants need not
    /// > write a dedicated `catch`/`switch` arm for this case.
    case timeout

    /// A WebView or ACS technical failure. `message` is one of the SDK's
    /// internal markers — e.g. `navigation_error_<code>`,
    /// `"Unsafe navigation blocked"`, `"timeout"`, `3DS error <code>`, or
    /// `mollie_error_<code>`.
    ///
    /// > Tip: Mostly transient — allow a retry. `"Unsafe navigation
    /// > blocked"` is a security signal — contact support. Do not show the
    /// > raw `message` to the cardholder; map it to a generic "couldn't
    /// > complete authentication".
    ///
    /// - Parameter message: An internal, developer-facing failure marker.
    case sdkError(message: String)

    /// An unclassified 3DS failure.
    ///
    /// > Note: Reserved — not currently emitted. Merchants need not write a
    /// > dedicated `catch`/`switch` arm for this case.
    ///
    /// - Parameters:
    ///   - code: An optional 3DS error code.
    ///   - message: A developer-facing failure description.
    case unknown(code: String?, message: String)
}
