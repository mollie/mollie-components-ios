/// A single field-level validation violation from a `422` response —
/// carried inside `MollieError.APIError.validationFailed([Violation])`.
///
/// > Tip: Map `name` to the corresponding form field and show `reason`
/// > inline. Validation violations are cardholder-retryable.
public struct Violation: Decodable, Equatable {
    /// The name of the form field that failed validation (e.g. `cardNumber`).
    public let name: String

    /// A display-ready reason the field was rejected (e.g. `is invalid`).
    public let reason: String
}
