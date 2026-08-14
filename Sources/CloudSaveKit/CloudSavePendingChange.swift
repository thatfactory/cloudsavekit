import CloudKit

/// Describes one locally durable CloudKit change waiting to be sent.
public enum CloudSavePendingChange: Hashable, Sendable {
    /// Saves or replaces the record with the specified identifier.
    case save(CKRecord.ID)

    /// Deletes the record with the specified identifier.
    case delete(CKRecord.ID)
}

extension CloudSavePendingChange {
    /// The record identifier represented by this durable host change.
    var recordID: CKRecord.ID {
        switch self {
        case .save(let recordID), .delete(let recordID):
            recordID
        }
    }

    /// The CKSyncEngine change represented by this durable host change.
    var syncEngineChange: CKSyncEngine.PendingRecordZoneChange {
        switch self {
        case .save(let recordID):
            .saveRecord(recordID)
        case .delete(let recordID):
            .deleteRecord(recordID)
        }
    }
}
