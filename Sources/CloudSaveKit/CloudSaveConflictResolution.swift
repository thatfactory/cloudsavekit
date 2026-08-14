import CloudKit

/// Selects how the engine should finish handling a server-record conflict.
public enum CloudSaveConflictResolution: Sendable {
    /// Accepts the server record and removes the local pending save.
    case acceptServer

    /// Persists and retries a merged record based on the server record.
    case retry(mergedRecord: CKRecord)

    /// Preserves the conflict for a user-facing application decision.
    case requiresUserDecision
}
