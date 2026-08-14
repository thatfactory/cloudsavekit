import CloudKit

/// Identifies the independent work item that must recover from a failure.
enum CloudSaveFailureContext: Equatable, Sendable {
    /// A host persistence callback must recover before the engine can restart.
    case hostPersistence

    /// A fetch or send operation must complete in a later generation.
    case operation(CloudSaveOperation)

    /// A specific record change must succeed or be explicitly discarded.
    case record(CKRecord.ID)

    /// A specific record-zone change must succeed.
    case zone(CKRecordZone.ID)
}

extension CloudSaveFailureContext {
    /// The record identifier supplied to the host failure callback, when relevant.
    var recordID: CKRecord.ID? {
        guard case .record(let recordID) = self else {
            return nil
        }

        return recordID
    }
}
