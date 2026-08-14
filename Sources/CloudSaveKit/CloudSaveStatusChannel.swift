import Foundation

/// Owns the bounded asynchronous channel for current synchronization status.
struct CloudSaveStatusChannel: Sendable {
    let continuation: AsyncStream<CloudSaveStatus>.Continuation
    let stream: AsyncStream<CloudSaveStatus>

    /// Creates a channel that retains only its latest unconsumed status.
    init() {
        let channel = AsyncStream.makeStream(
            of: CloudSaveStatus.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        channel.continuation.yield(.idle)
        continuation = channel.continuation
        stream = channel.stream
    }
}
