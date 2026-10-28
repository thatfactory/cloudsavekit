import Foundation

@testable import CloudSaveKit

/// Exercises the public session facade while CKSyncEngine transport remains credential-free.
actor CloudSaveSessionEngineMock: CloudSaveSessionEngine {
    nonisolated let statusUpdates = AsyncStream<CloudSaveStatus> { $0.finish() }
    private let client: (any CloudSaveClient)?
    private var sendError: (any Error)?
    private var retirement: CloudSaveTestSuspension?
    private(set) var restored: [CloudSavePendingChange] = []
    private(set) var enqueued: [CloudSavePendingChange] = []
    private(set) var retireCount = 0
    private(set) var sendCount = 0

    /// Optionally restores an actual guarded client's ledger through the same persistence seam.
    init(client: (any CloudSaveClient)? = nil) { self.client = client }

    /// Injects an engine transport failure.
    func failSend(_ error: any Error) { sendError = error }

    /// Holds teardown so tests can prove invalidation is visible before cancellation finishes.
    func pauseRetirement(_ suspension: CloudSaveTestSuspension) { retirement = suspension }

    /// Restores the fixture's durable pending mutations.
    func start() async throws { restored = try await client?.pendingChanges() ?? [] }

    /// Completes a test fetch without network work.
    func fetchNow() {}

    /// Emits the configured send failure before acknowledgements.
    func sendNow() throws {
        sendCount += 1
        if let sendError {
            throw sendError
        }
    }

    /// Uses the same send outcome for combined-operation tests.
    func syncNow() throws { try sendNow() }

    /// Counts only enqueues that crossed the session's active gate.
    func enqueue(_ changes: [CloudSavePendingChange]) { enqueued += changes }

    /// Records terminal shutdown without deleting local mutations.
    func retire() async {
        retireCount += 1
        await retirement?.suspend()
    }
}
