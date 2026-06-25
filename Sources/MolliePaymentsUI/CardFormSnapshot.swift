import Foundation

/// Raw, unvalidated snapshot of what the user has entered in the card form.
///
/// MR4 emits this as-typed: PAN with whatever spacing the user inserted,
/// expiry as the raw `MM/YY` string, CVC and cardholder name as-typed. MR5
/// layers Luhn, expiry parsing, and CVC length-by-scheme on top before this
/// shape becomes a `CardSubmissionData` for the coordinator.
///
/// PCI: the PAN and CVC fields are sensitive cardholder data. The host
/// coordinator MUST call `zero()` after it has finished consuming the
/// snapshot (e.g. after handing the PAN to the tokeniser), so the strings
/// stop living on the heap longer than strictly necessary. Pure
/// String-based zeroing in Swift is best-effort — the backing storage is
/// opaque — but dropping the references promptly minimises the window
/// during which the secret value sits in memory. See
/// `MollieCardFormViewController.handleSubmit` for the producer side.
package struct CardFormSnapshot: Equatable {
    package var cardholderName: String
    package var cardNumber: String
    package var expiry: String
    package var cvc: String

    package init(
        cardholderName: String,
        cardNumber: String,
        expiry: String,
        cvc: String
    ) {
        self.cardholderName = cardholderName
        self.cardNumber = cardNumber
        self.expiry = expiry
        self.cvc = cvc
    }

    /// Drop the producer's reference to the sensitive fields (`cardNumber`,
    /// `cvc`) by overwriting them with empty strings. **This is "drop the
    /// reference," not "memory-wipe."**
    ///
    /// Important caveats — `CardFormSnapshot` is a value type, so:
    ///
    /// 1. Any caller that received a copy (e.g. the `onSubmit` closure in
    ///    `MollieCardFormViewController.handleSubmit`) owns its own copy
    ///    of the strings and must zero its own snapshot independently;
    ///    zeroing one copy does not affect any other.
    /// 2. Swift `String` storage is opaque (small-string optimisation, COW,
    ///    possibly bridged to NSString). The bytes that backed the PAN or
    ///    CVC may continue to live on the heap until the allocator
    ///    reclaims the page; small-string-optimised strings live inside
    ///    the struct and are released with it. True scrubbing requires
    ///    byte-backed (`[UInt8]`) storage with an explicit `memset`,
    ///    which the current producer does not yet provide.
    ///
    /// One-shot semantics — calling it twice is a no-op. The producer
    /// (`MollieCardFormViewController.handleSubmit`) calls this on its
    /// local after invoking `onSubmit?`, so the VC's stack reference is
    /// dropped immediately; upstream callers retain responsibility for
    /// their own copies.
    package mutating func zero() {
        cardNumber = ""
        cvc = ""
    }
}
