public enum ParsedEnum<T: RawRepresentable> where T.RawValue == String {
    case known(T)
    case unknown(String)
}

extension ParsedEnum: Decodable where T: Decodable {
    public init(from decoder: Decoder) throws {
        let raw = try String(from: decoder)
        self = T(rawValue: raw).map { .known($0) } ?? .unknown(raw)
    }
}

extension ParsedEnum: Equatable where T: Equatable {}
extension ParsedEnum: Sendable where T: Sendable {}
