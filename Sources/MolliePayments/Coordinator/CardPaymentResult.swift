import MollieCore

/// Terminal outcome of `CardPaymentCoordinator.submit`.
///
/// `MollieError` itself is not `Equatable` in Phase 1, so this enum does
/// not synthesize `Equatable`. Tests inspect cases via pattern matching.
/// Made public for demo target access; will be re-evaluated when MollieComponents umbrella ships in Phase 4.
public enum CardPaymentResult {
    case completed(SessionResponse)
    case failed(MollieError)
    case cancelled
}
