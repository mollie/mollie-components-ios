/// Placeholder `MollieChannelsClient`. Pusher integration is deferred to a follow-up
/// change (see the "PusherSwift integration" design notes). `SessionEventConsumer` falls
/// back to `SessionPoller` when this no-op client is wired in.
/// Made public for demo target access; will be re-evaluated once the `MollieComponents` umbrella target ships.
public final class NoOpChannelsClient: MollieChannelsClient {
    public init() {}

    public func subscribe(to _: String) async throws -> AsyncStream<ChannelDoorbell> {
        AsyncStream { continuation in continuation.finish() }
    }

    public func unsubscribe(from _: String) async {}

    public func disconnect() async {}
}
