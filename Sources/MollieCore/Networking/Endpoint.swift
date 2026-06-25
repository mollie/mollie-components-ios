import Foundation

public struct Endpoint<Response: Decodable> {
    package let path: String
    package let method: HTTPMethod
    let body: (any Encodable)?
    let requiresAuth: Bool
    package let headers: [String: String]

    package init(
        path: String,
        method: HTTPMethod,
        body: (any Encodable)? = nil,
        requiresAuth: Bool = true,
        headers: [String: String] = [:]
    ) {
        self.path = path
        self.method = method
        self.body = body
        self.requiresAuth = requiresAuth
        self.headers = headers
    }

    func asURLRequest(baseURL: URL, clientAccessToken: String?) throws -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method.rawValue
        if requiresAuth, let token = clientAccessToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        return request
    }
}
