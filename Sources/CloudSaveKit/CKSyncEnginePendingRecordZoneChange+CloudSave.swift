import CloudKit

extension CKSyncEngine.PendingRecordZoneChange {
    /// The record identifier represented by this CKSyncEngine change.
    var recordID: CKRecord.ID? {
        switch self {
        case .saveRecord(let recordID), .deleteRecord(let recordID):
            recordID
        @unknown default:
            nil
        }
    }
}
