import MollieCore

/// Terminal outcome of `MolliePaymentSheet.present(...)`.
///
/// Marked `@unchecked Sendable` because `MollieError` wraps non-Sendable
/// Foundation error types (`URLError`, `DecodingError`, generic `Error`).
/// In practice the result is constructed on a single actor and handed off
/// to the awaiting caller, so cross-thread mutation is not a hazard;
/// the `@unchecked` annotation mirrors the precedent set by
/// `MollieCore.AnyCodable`.
public enum MolliePaymentResult: @unchecked Sendable {
    case completed(MolliePayment)
    case failed(MollieError)
    case cancelled
}
