import CloudKit
import Foundation

/// Owns one notification registration and removes it when the coordinator is released.
/// Foundation's immutable observer token is used only for removal in deinit.
final class CloudSaveAccountNotifications: @unchecked Sendable {
    let changes: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    private let observer: any NSObjectProtocol

    /// Registers before any account query or engine creation; notifications carry no identity.
    init() {
        let channel = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        changes = channel.stream
        continuation = channel.continuation
        observer = NotificationCenter.default.addObserver(forName: .CKAccountChanged, object: nil, queue: nil) { _ in
            channel.continuation.yield(())
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(observer)
        continuation.finish()
    }
}
