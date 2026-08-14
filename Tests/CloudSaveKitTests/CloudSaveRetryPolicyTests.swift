import CloudKit
import Testing

@testable import CloudSaveKit

@Suite("Cloud save retry policy")
struct CloudSaveRetryPolicyTests {
    @Test("Recognizes task and CloudKit cancellation")
    func recognizesCancellation() {
        #expect(CloudSaveRetryPolicy.isCancellation(CancellationError()))
        #expect(CloudSaveRetryPolicy.isCancellation(CKError(.operationCancelled)))
        #expect(!CloudSaveRetryPolicy.isCancellation(CKError(.networkFailure)))
    }

    @Test(
        "Leaves transport and scheduling failures to CKSyncEngine",
        arguments: [
            CKError.Code.accountTemporarilyUnavailable,
            .networkFailure,
            .networkUnavailable,
            .notAuthenticated,
            .operationCancelled,
            .requestRateLimited,
            .serviceUnavailable,
            .zoneBusy,
        ]
    )
    func leavesRetryableFailureToCKSyncEngine(code: CKError.Code) {
        #expect(
            !CloudSaveRetryPolicy.requiresApplicationAttention(
                for: CKError(code)
            )
        )
    }

    @Test(
        "Requires application attention for semantic and permanent failures",
        arguments: [
            CKError.Code.badContainer,
            .permissionFailure,
            .quotaExceeded,
            .serverRecordChanged,
            .unknownItem,
            .zoneNotFound,
        ]
    )
    func requiresApplicationAttention(code: CKError.Code) {
        #expect(
            CloudSaveRetryPolicy.requiresApplicationAttention(
                for: CKError(code)
            )
        )
    }
}
