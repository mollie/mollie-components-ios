import MollieCore

package enum ThreeDSResult: Equatable {
    case authenticated
    case failed(reason: ThreeDSFailureReason)
    case cancelled
}

/// A parsed interceptor-page bridge event. Distinguishes the
/// "interactive UI is about to show" signal (`type == "challenge"`) from a
/// terminal `ThreeDSResult` (`complete` / `error` / `canceled`). The
/// controller defers modal presentation until `.challengeEscalation`
/// arrives, so an ACS-level frictionless auth (terminal with no preceding
/// challenge) never flashes the sheet.
package enum ThreeDSBridgeEvent: Equatable {
    case challengeEscalation
    case result(ThreeDSResult)
}
