#if canImport(UIKit)
    import UIKit

    /// Finds the topmost view controller that `MolliePaymentSheet.present(...)`
    /// can present from in a SwiftUI app.
    ///
    /// The walk is: foreground-active `UIWindowScene` → key window → root
    /// view controller → topmost already-presented descendant. SwiftUI hosts
    /// don't expose a `UIViewController` directly to user code, so the
    /// SwiftUI view-modifier needs this lookup to bridge into the UIKit
    /// `present(...)` path.
    ///
    /// Returns `nil` in two real situations:
    /// - the app has no active scene (background launch, app extension)
    /// - the active scene has no key window yet (very early in launch)
    /// Both are caller-handled by surfacing `.failed(.invalidConfiguration)`.
    @MainActor
    package enum SceneRootResolver {
        package static func activeRootViewController(
            application: UIApplication = .shared
        ) -> UIViewController? {
            let foregroundScene = application.connectedScenes
                .first { ($0 as? UIWindowScene)?.activationState == .foregroundActive }
                as? UIWindowScene
            guard let scene = foregroundScene else { return nil }
            let keyWindow = scene.windows.first { $0.isKeyWindow } ?? scene.windows.first
            guard let root = keyWindow?.rootViewController else { return nil }
            return Self.topmostPresented(from: root)
        }

        package static func topmostPresented(from controller: UIViewController) -> UIViewController {
            var current = controller
            while let next = current.presentedViewController, !next.isBeingDismissed {
                current = next
            }
            return current
        }
    }
#endif
