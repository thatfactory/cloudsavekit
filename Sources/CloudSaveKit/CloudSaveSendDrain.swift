import Foundation

/// Fences batch creation during an SDK engine change and waits for started sends to finish.
struct CloudSaveSendDrain: Sendable {
    private(set) var isClosed = false
    private var activeSends = 0
    private var hasIssuedBatch = false
    private var waiter: (id: UUID, continuation: CheckedContinuation<Void, any Error>)?

    var isIdle: Bool { activeSends == 0 && !hasIssuedBatch }

    mutating func beginSend() {
        activeSends += 1
    }

    mutating func finishSend() {
        activeSends = max(0, activeSends - 1)
        if activeSends == 0 { hasIssuedBatch = false }
        if isIdle { resumeWaiter() }
    }

    mutating func issueBatch() {
        hasIssuedBatch = true
    }

    mutating func closeAdmission() {
        isClosed = true
    }

    mutating func openAdmission() {
        isClosed = false
    }

    mutating func wait(id: UUID, continuation: CheckedContinuation<Void, any Error>) {
        if isIdle {
            continuation.resume()
        } else {
            precondition(waiter == nil, "The explicit operation lock admits one drain waiter.")
            waiter = (id, continuation)
        }
    }

    mutating func cancelWait(id: UUID? = nil) {
        guard id == nil || waiter?.id == id else { return }
        let continuation = waiter?.continuation
        waiter = nil
        continuation?.resume(throwing: CancellationError())
    }

    mutating func invalidate() {
        activeSends = 0
        hasIssuedBatch = false
        isClosed = false
        let continuation = waiter?.continuation
        waiter = nil
        continuation?.resume(throwing: CloudSaveEngineError.hostRecoveryRequired)
    }

    private mutating func resumeWaiter() {
        let continuation = waiter?.continuation
        waiter = nil
        continuation?.resume()
    }
}
