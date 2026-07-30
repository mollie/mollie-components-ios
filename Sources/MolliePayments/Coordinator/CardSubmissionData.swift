public struct CardSubmissionData: Equatable {
    public let cardholderName: String?
    /// PCI-sensitive. `var` so `zero()` can best-effort drop the reference
    /// after tokenisation; see the `zero()` caveat.
    public var cardNumber: String
    public let expiryMonth: Int
    public let expiryYear: Int
    /// PCI-sensitive. `var` so `zero()` can best-effort drop the reference
    /// after tokenisation; see the `zero()` caveat.
    public var cvc: String

    public init(cardholderName: String?, cardNumber: String, expiryMonth: Int, expiryYear: Int, cvc: String) {
        self.cardholderName = cardholderName
        self.cardNumber = cardNumber
        self.expiryMonth = expiryMonth
        self.expiryYear = expiryYear
        self.cvc = cvc
    }

    /// Best-effort clear of the PCI-sensitive fields (`cardNumber`, `cvc`) by
    /// overwriting them with empty strings, mirroring `CardFormSnapshot.zero()`.
    /// **This is "drop the reference," not "memory-wipe."**
    ///
    /// Swift `String` storage is opaque (small-string optimisation, COW,
    /// possibly bridged to NSString): the bytes that backed the PAN or CVC may
    /// continue to live on the heap until the allocator reclaims the page.
    /// True scrubbing requires byte-backed (`[UInt8]`) storage with an explicit
    /// `memset`, which the current producers do not provide. Non-PCI fields
    /// (name, expiry) are intentionally preserved. Calling it twice is a no-op.
    public mutating func zero() {
        cardNumber = ""
        cvc = ""
    }
}

/// Belt-and-braces: the struct holds the raw PAN, CVC, cardholder name and
/// expiry. Any reflection-based dump (`String(describing:)`, `String(reflecting:)`,
/// `dump(_:)`, the Swift runtime's default `print` of a struct, third-party
/// crash reporters that auto-mirror locals) would otherwise emit the cleartext
/// fields. Conforming to `CustomDebugStringConvertible` forces a fixed redacted
/// string regardless of how the struct is rendered. Mirrors
/// `TokenizeRequest.debugDescription`.
extension CardSubmissionData: CustomDebugStringConvertible {
    public var debugDescription: String {
        "CardSubmissionData(redacted)"
    }
}
