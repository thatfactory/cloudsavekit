import Foundation

/// Narrow internal synchronization seam; production sessions always use the existing engine.
protocol CloudSaveSessionEngine: Actor {
    nonisolated var statusUpdates: AsyncStream<CloudSaveStatus> { get }
    func start() async throws
    func fetchNow() async throws
    func sendNow() async throws
    func syncNow() async throws
    func enqueue(_ changes: [CloudSavePendingChange]) async
    func retire() async
}

extension CloudSaveEngine: CloudSaveSessionEngine {}
