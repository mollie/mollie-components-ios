import Foundation
import MollieCore
#if canImport(UIKit)
    import UIKit
#endif

/// Builder for the `DeviceFingerprint` value sent with `PATCH /sessions/{token}/details`
/// and `POST /checkout-attempts`. Lives in its own file (previously a free
/// `internal` function in SessionPatchRequest.swift) so both call-sites share
/// the same implementation and the screen-metrics access stays main-actor-scoped.
///
/// The web SDK collects a richer browser fingerprint; on iOS we map the
/// equivalent fields to device-derived or fixed values.
package enum DeviceFingerprintBuilder {
    /// Build the current device fingerprint.
    ///
    /// `@MainActor` because `UIScreen` access is documented as main-thread-only.
    /// `UIScreen.main` is deprecated as of iOS 16 in favour of resolving the
    /// screen from a connected `UIWindowScene`; we fall back to `UIScreen.main`
    /// when no scene is attached (background launch, unit-test host).
    @MainActor
    package static func current() -> DeviceFingerprint {
        let offsetMinutes = -TimeZone.current.secondsFromGMT() / 60
        let width: String
        let height: String
        #if canImport(UIKit)
            let bounds = resolveScreenBounds()
            width = String(Int(bounds.width))
            height = String(Int(bounds.height))
        #else
            width = "375"
            height = "812"
        #endif
        return DeviceFingerprint(
            language: Locale.preferredLanguages.first ?? "en-US",
            javascriptEnabled: false,
            screenWidth: width,
            screenHeight: height,
            timeZoneOffset: String(offsetMinutes),
            javaEnabled: false,
            colorDepth: "24"
        )
    }

    #if canImport(UIKit)
        @MainActor
        private static func resolveScreenBounds() -> CGRect {
            let scenes = UIApplication.shared.connectedScenes
            if let windowScene = scenes.compactMap({ $0 as? UIWindowScene }).first {
                return windowScene.screen.bounds
            }
            // Fallback for hosts without an attached scene (e.g. background
            // launch, xctest harness). `UIScreen.main` is deprecated but
            // remains the only reliable fallback in those contexts.
            return UIScreen.main.bounds
        }
    #endif
}
