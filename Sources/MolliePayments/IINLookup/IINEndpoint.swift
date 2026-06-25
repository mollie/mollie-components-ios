import MollieCore

enum IINEndpoint {
    static func lookup(prefix: String) -> Endpoint<IINResult> {
        Endpoint(path: "v1/iin/\(prefix)", method: .get, body: nil, requiresAuth: false)
    }
}
