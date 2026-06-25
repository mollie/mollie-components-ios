import Foundation

/// Lightweight type-erased Codable wrapper for heterogeneous JSON dictionaries
/// such as NextAction.params. Handles primitive JSON value types only.
///
/// Equatable is implemented via NSObject bridging because `value: Any` cannot
/// participate in Swift's synthesized Equatable. Bridging works for the JSON
/// primitive types (Bool, Int, Double, String, [Any], [String: Any], NSNull)
/// this wrapper actually decodes.
///
/// Sendable is `@unchecked` because `value: Any` defeats the compiler's check,
/// but the value is decoded once and never mutated, so it is safe to share
/// across actors.
public struct AnyCodable: Codable, Equatable, @unchecked Sendable {
    public let value: Any

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let boolValue = try? container.decode(Bool.self) {
            value = boolValue
        } else if let intValue = try? container.decode(Int.self) {
            value = intValue
        } else if let doubleValue = try? container.decode(Double.self) {
            value = doubleValue
        } else if let stringValue = try? container.decode(String.self) {
            value = stringValue
        } else if let arrayValue = try? container.decode([AnyCodable].self) {
            value = arrayValue.map(\.value)
        } else if let dictValue = try? container.decode([String: AnyCodable].self) {
            value = dictValue.mapValues { $0.value }
        } else {
            value = NSNull()
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case let boolValue as Bool:
            try container.encode(boolValue)
        case let intValue as Int:
            try container.encode(intValue)
        case let doubleValue as Double:
            try container.encode(doubleValue)
        case let stringValue as String:
            try container.encode(stringValue)
        case let array as [Any]:
            var container = encoder.unkeyedContainer()
            for element in array {
                try AnyCodable(element).encode(to: container.superEncoder())
            }
        case let dict as [String: Any]:
            var container = encoder.container(keyedBy: AnyCodableCodingKey.self)
            for (key, value) in dict {
                let codingKey = AnyCodableCodingKey(key)
                try AnyCodable(value).encode(to: container.superEncoder(forKey: codingKey))
            }
        default:
            try container.encodeNil()
        }
    }

    public static func == (lhs: AnyCodable, rhs: AnyCodable) -> Bool {
        let lhsObject = lhs.value as AnyObject
        let rhsObject = rhs.value as AnyObject
        return lhsObject.isEqual(rhsObject)
    }
}

private extension AnyCodable {
    init(_ value: Any) {
        self.value = value
    }
}

private struct AnyCodableCodingKey: CodingKey {
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
