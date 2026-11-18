import Foundation
import Testing

@testable import CloudSaveKit

@Suite("Cloud save send drain")
struct CloudSaveSendDrainTests {
    @Test func drainingRejectsNewBatchesUntilEveryStartedSendEnds() async throws {
        var drain = CloudSaveSendDrain()
        drain.beginSend()
        drain.issueBatch()
        drain.beginSend()
        drain.closeAdmission()

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            drain.wait(id: UUID(), continuation: continuation)
            drain.finishSend()
            #expect(drain.isClosed)
            #expect(!drain.isIdle)
            drain.finishSend()
        }

        #expect(drain.isIdle)
        #expect(drain.isClosed)
        drain.openAdmission()
        #expect(!drain.isClosed)
    }

    @Test func issuedBatchIsOutstandingUntilItsSendEnds() {
        var drain = CloudSaveSendDrain()
        drain.issueBatch()
        drain.closeAdmission()

        #expect(!drain.isIdle)
        drain.finishSend()
        #expect(drain.isIdle)
    }

    @Test func cancellationKeepsAnOutstandingSendTracked() async {
        var drain = CloudSaveSendDrain()
        drain.beginSend()
        drain.closeAdmission()

        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let waiter = UUID()
                drain.wait(id: waiter, continuation: continuation)
                drain.cancelWait(id: UUID())
                drain.cancelWait(id: waiter)
            }
            Issue.record("Expected cancellation.")
        } catch {
            #expect(error is CancellationError)
        }

        #expect(!drain.isIdle)
        drain.openAdmission()
        drain.finishSend()
        #expect(drain.isIdle)
    }

    @Test func invalidationReleasesTheWaiterAndFencesItsOldEngine() async {
        var drain = CloudSaveSendDrain()
        drain.beginSend()
        drain.closeAdmission()

        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                drain.wait(id: UUID(), continuation: continuation)
                drain.invalidate()
            }
            Issue.record("Expected invalidation.")
        } catch {
            #expect(error as? CloudSaveEngineError == .hostRecoveryRequired)
        }

        #expect(drain.isIdle)
        #expect(!drain.isClosed)
    }
}
