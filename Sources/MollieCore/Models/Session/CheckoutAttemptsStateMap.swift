import Foundation

/// Map of checkout-attempt token → per-attempt session state.
/// Each value is the same `SessionResponse` shape used by the legacy GET session endpoint.
/// Mirrors the equivalent checkout-attempts state map in the web integration.
///
/// The server returns this endpoint as either:
///   - `[]` (empty JSON array) — no per-attempt state populated yet (typical
///     first few polls right after `POST /checkout-attempts` resolves)
///   - `{}` or `{"chatt_x": {...}}` — the state map proper
///
/// Both shapes need to decode successfully so the poller can keep polling
/// past the initial "empty" responses without surfacing a decode error to
/// the caller. The wrapper around `[String: SessionResponse]` is the
/// smallest change that preserves the `map[token]` lookup site in
/// `SessionPoller.pollAttempt`.
public struct CheckoutAttemptsStateMap: Decodable, Equatable, Sendable {
    public let entries: [String: SessionResponse]

    public init(entries: [String: SessionResponse] = [:]) {
        self.entries = entries
    }

    public init(from decoder: Decoder) throws {
        // The backend returns `[]` when there are no per-attempt states yet
        // (instead of `{}`). Decoding `[]` as `[String: SessionResponse]`
        // via `JSONDecoder` triggers an internal `_Int128` fatalError on
        // some Swift/Foundation versions (the decoder mis-routes the empty
        // array through a Double → Int conversion path). `try?` does NOT
        // catch fatalErrors. To stay robust, decode an empty-array sentinel
        // case first; the unkeyed container only crashes if it tries to
        // *advance*, which it doesn't on an empty array.
        // `UnkeyedDecodingContainer` exposes `count: Int?` but no `isEmpty`,
        // so the explicit `== 0` is the documented way to test emptiness here.
        // swiftlint:disable:next empty_count
        if let unkeyed = try? decoder.unkeyedContainer(), unkeyed.count == 0 {
            entries = [:]
            return
        }
        // Otherwise expect the dictionary shape keyed by checkout-attempt token.
        let container = try decoder.singleValueContainer()
        entries = try container.decode([String: SessionResponse].self)
    }

    public subscript(token: String) -> SessionResponse? {
        entries[token]
    }
}
