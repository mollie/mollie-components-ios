import Foundation
import MollieCore

/// Serializes a single in-flight operation. If called while another
/// operation is running, the second call throws
/// `MollieError.invalidConfiguration` rather than queueing.
///
/// Used by `CardPaymentCoordinator` to enforce the "no double-submit"
/// contract — the second tap on Pay must surface immediately instead of
/// silently waiting for the first to complete.
actor SingleFlight {
    private var inFlight = false

    func guarded<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
        if inFlight {
            throw MollieError.invalidConfiguration(
                field: "submit",
                reason: "A payment submission is already in progress."
            )
        }
        inFlight = true
        defer { inFlight = false }
        return try await operation()
    }
}
