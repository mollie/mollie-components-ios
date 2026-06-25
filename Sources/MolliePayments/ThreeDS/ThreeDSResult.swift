import MollieCore

package enum ThreeDSResult: Equatable {
    case authenticated
    case failed(reason: ThreeDSFailureReason)
    case cancelled
}
