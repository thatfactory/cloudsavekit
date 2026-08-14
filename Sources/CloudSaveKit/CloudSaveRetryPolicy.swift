import CloudKit

/// Centralizes which CloudKit errors remain under CKSyncEngine's retry ownership.
enum CloudSaveRetryPolicy {
    /// Returns whether a failure represents intentional task or CloudKit cancellation.
    static func isCancellation(_ error: any Error) -> Bool {
        error is CancellationError
            || (error as? CKError)?.code == .operationCancelled
    }

    /// Returns whether a failure requires application attention.
    static func requiresApplicationAttention(for error: CKError) -> Bool {
        switch error.code {
        case .accountTemporarilyUnavailable, .networkFailure, .networkUnavailable,
            .notAuthenticated, .operationCancelled, .requestRateLimited,
            .serviceUnavailable, .zoneBusy:
            false
        default:
            true
        }
    }
}
