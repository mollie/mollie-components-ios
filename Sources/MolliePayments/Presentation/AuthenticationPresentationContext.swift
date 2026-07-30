#if canImport(UIKit)
    import UIKit

    /// Made public for demo target access; will be re-evaluated once the `MollieComponents` umbrella target ships.
    public protocol AuthenticationPresentationContext: AnyObject, Sendable {
        @MainActor func presentationViewController() -> UIViewController
    }
#endif
