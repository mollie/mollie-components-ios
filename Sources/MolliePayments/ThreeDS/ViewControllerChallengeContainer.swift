#if canImport(UIKit)
    import UIKit

    /// Modal-friendly ChallengeContainer. The coordinator presents the 3DS
    /// challenge view controller modally from this container's
    /// presentingViewController. Swipe-to-dismiss resolves .cancelled.
    /// Made public for demo target access.
    public final class ViewControllerChallengeContainer: ChallengeContainer, @unchecked Sendable {
        public let presentingViewController: UIViewController

        public init(presentingViewController: UIViewController) {
            self.presentingViewController = presentingViewController
        }
    }
#endif
