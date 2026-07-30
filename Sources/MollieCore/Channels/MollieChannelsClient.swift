/// Made public for demo target access; will be re-evaluated once the `MollieComponents` umbrella target ships.
public protocol MollieChannelsClient: Sendable {
    /// Subscribe to the session's channel. Emits a `ChannelDoorbell` tick on
    /// every server signal — a doorbell, not data. The consumer owns the
    /// re-fetch + diff; the transport never maps session state itself.
    func subscribe(to sessionToken: String) async throws -> AsyncStream<ChannelDoorbell>
    func unsubscribe(from sessionToken: String) async
    func disconnect() async
}
