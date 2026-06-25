public protocol HTTPClient: Sendable {
    func perform<T: Decodable>(_ endpoint: Endpoint<T>) async throws -> T
}
