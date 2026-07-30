import Foundation

/// Opaque host for a 3-D Secure challenge UI. The presenter pushes its
/// challenge view onto this container; the container observes user-initiated
/// dismissal (back gesture / back button) and notifies the presenter so it
/// can release any held continuation cleanly.
///
/// Declared UIKit-free so `ChallengePresenting` remains mockable from tests
/// that don't import UIKit. The concrete UIKit implementation
/// (`UINavigationChallengeContainer`) is platform-guarded and lives next to
/// `ThreeDSCoordinator`.
/// Made public for demo target access; will be re-evaluated once the `MollieComponents` umbrella target ships.
public protocol ChallengeContainer: AnyObject, Sendable {}
