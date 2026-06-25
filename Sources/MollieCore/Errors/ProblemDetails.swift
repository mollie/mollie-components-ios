/// An RFC 7807 *Problem Details* payload describing why a session failed —
/// carried by `MollieError.sessionFailed(_:)`.
///
/// For a genuine backend decline these fields come straight from the
/// service. The SDK also **synthesizes** an instance when it blocks an
/// unsafe URL: `title` is `"invalid_configuration"` and `detail` is
/// `"Unsafe 3DS challenge URL"` or `"Unsafe redirect URL"`. When the SDK
/// cannot classify a failure at all it falls back to a synthesized instance
/// with `title: "unknown"`.
public struct ProblemDetails: Codable, Sendable, Equatable {
    /// A URI reference identifying the problem type, when the service
    /// provides one.
    public let type: String?

    /// A short, human-readable summary of the problem. For SDK-synthesized
    /// instances this is `"invalid_configuration"` (unsafe URL blocked) or
    /// `"unknown"` (unclassified fallback).
    public let title: String?

    /// A human-readable explanation specific to this occurrence — the most
    /// useful field to surface to the cardholder for a genuine decline. For
    /// the SDK's unsafe-URL block this is `"Unsafe 3DS challenge URL"` or
    /// `"Unsafe redirect URL"`.
    public let detail: String?

    /// The HTTP status code associated with the problem, when present.
    public let status: Int?

    /// A URI reference identifying the specific occurrence, when present.
    public let instance: String?

    /// Any additional, non-standard members from the problem document,
    /// preserved as decoded JSON values.
    public let extensions: [String: AnyCodable]

    public init(
        type: String? = nil,
        title: String? = nil,
        detail: String? = nil,
        status: Int? = nil,
        instance: String? = nil,
        extensions: [String: AnyCodable] = [:]
    ) {
        self.type = type
        self.title = title
        self.detail = detail
        self.status = status
        self.instance = instance
        self.extensions = extensions
    }

    private struct DynamicKey: CodingKey {
        var stringValue: String
        var intValue: Int?

        init(_ value: String) {
            stringValue = value
            intValue = nil
        }

        init?(stringValue: String) {
            self.stringValue = stringValue
            intValue = nil
        }

        init?(intValue: Int) {
            stringValue = String(intValue)
            self.intValue = intValue
        }
    }

    private static let knownKeys: Set<String> = ["type", "title", "status", "detail", "instance"]

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicKey.self)
        type = try container.decodeIfPresent(String.self, forKey: DynamicKey("type"))
        title = try container.decodeIfPresent(String.self, forKey: DynamicKey("title"))
        detail = try container.decodeIfPresent(String.self, forKey: DynamicKey("detail"))
        status = try container.decodeIfPresent(Int.self, forKey: DynamicKey("status"))
        instance = try container.decodeIfPresent(String.self, forKey: DynamicKey("instance"))

        var extensions: [String: AnyCodable] = [:]
        for key in container.allKeys where !Self.knownKeys.contains(key.stringValue) {
            if let value = try container.decodeIfPresent(AnyCodable.self, forKey: key) {
                extensions[key.stringValue] = value
            }
        }
        self.extensions = extensions
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: DynamicKey.self)
        try container.encodeIfPresent(type, forKey: DynamicKey("type"))
        try container.encodeIfPresent(title, forKey: DynamicKey("title"))
        try container.encodeIfPresent(detail, forKey: DynamicKey("detail"))
        try container.encodeIfPresent(status, forKey: DynamicKey("status"))
        try container.encodeIfPresent(instance, forKey: DynamicKey("instance"))
        for (key, value) in extensions where !Self.knownKeys.contains(key) {
            try container.encode(value, forKey: DynamicKey(key))
        }
    }
}
