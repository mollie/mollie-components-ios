/// Placeholder `MollieChannelsClient`. Pusher integration is deferred to a follow-up
/// MR (see Phase 2 plan, "PusherSwift integration"). `SessionEventConsumer` falls
/// back to `SessionPoller` when this no-op client is wired in.
/// Made public for demo target access; will be re-evaluated when MollieComponents umbrella ships in Phase 4.
public final class NoOpChannelsClient: MollieChannelsClient {
    public init() {}

    public func subscribe(to _: String) async throws -> AsyncStream<ChannelEvent> {
        AsyncStream { continuation in continuation.finish() }
    }

    public func unsubscribe(from _: String) async {}

    public func disconnect() async {}
}
