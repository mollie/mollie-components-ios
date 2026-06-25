/// Made public for demo target access; will be re-evaluated when MollieComponents umbrella ships in Phase 4.
public protocol MollieChannelsClient: Sendable {
    func subscribe(to sessionToken: String) async throws -> AsyncStream<ChannelEvent>
    func unsubscribe(from sessionToken: String) async
    func disconnect() async
}
