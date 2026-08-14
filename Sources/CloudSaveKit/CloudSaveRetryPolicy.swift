import CloudKit

/// Centralizes which CloudKit errors remain under CKSyncEngine's retry ownership.
enum CloudSaveRetryPolicy {
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
