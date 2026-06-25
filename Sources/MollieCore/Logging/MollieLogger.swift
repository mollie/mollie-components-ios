import Foundation

/// Lightweight stderr logger for SDK debugging.
///
/// Calls are stripped from release builds via `#if DEBUG`, so log statements
/// cannot leak sensitive data (card tokens, session bodies) to production
/// stderr. The `@autoclosure` on `message` avoids constructing the string at
/// all in release builds — there is no runtime cost when disabled.
///
/// Usage:
/// ```swift
/// MollieLogger.log("TokenizerClient", "→ POST \(url)")
/// ```
///
/// In Xcode, set the scheme to "Debug" to see logs; "Release" builds (TestFlight,
/// App Store) compile the log call sites out entirely.
public enum MollieLogger {
    public static func log(_ category: String, _ message: @autoclosure () -> String) {
        #if DEBUG
            fputs("[\(category)] \(message())\n", stderr)
        #endif
    }
}
