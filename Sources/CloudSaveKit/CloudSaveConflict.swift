import CloudKit

/// Contains the three record versions CloudKit provides for conflict resolution.
public struct CloudSaveConflict: Sendable {
    /// The record the client attempted to save.
    public let clientRecord: CKRecord

    /// The current record stored by CloudKit.
    public let serverRecord: CKRecord

    /// The common record ancestor, when CloudKit supplies one.
    public let ancestorRecord: CKRecord?

    /// Creates a semantic CloudKit conflict.
    public init(
        clientRecord: CKRecord,
        serverRecord: CKRecord,
        ancestorRecord: CKRecord?
    ) {
        self.clientRecord = clientRecord
        self.serverRecord = serverRecord
        self.ancestorRecord = ancestorRecord
    }
}
