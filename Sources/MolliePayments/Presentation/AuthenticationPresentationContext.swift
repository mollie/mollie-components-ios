#if canImport(UIKit)
    import UIKit

    /// Made public for demo target access; will be re-evaluated when MollieComponents umbrella ships in Phase 4.
    public protocol AuthenticationPresentationContext: AnyObject, Sendable {
        @MainActor func presentationViewController() -> UIViewController
    }
#endif
