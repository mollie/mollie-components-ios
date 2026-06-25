// MollieCore — foundational types for the Mollie iOS SDK.

/// Single source of truth for the SDK version. Bumped at release time; never
/// hardcode the version anywhere else. Read by clients that need to identify
/// themselves to backend services (e.g. the `Tokenisation-Agent` header).
///
/// Public API: keep `MollieSDKVersion` reading like a build-time constant.
/// Renaming would break every caller; the existing release process pins this name.
public let MollieSDKVersion = "0.1.0" // swiftlint:disable:this identifier_name
