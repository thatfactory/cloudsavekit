import CloudKit

/// Connects ``CloudSaveEngine`` to an application's local persistence layer.
public protocol CloudSaveClient: Sendable {
    /// Returns all locally durable changes that still need to reach CloudKit.
    func pendingChanges() async throws -> [CloudSavePendingChange]

    /// Materializes the current local value for a pending record save.
    func record(for recordID: CKRecord.ID) async -> CKRecord?

    /// Persists CKSyncEngine's opaque state after every state update.
    func persist(stateSerialization: CKSyncEngine.State.Serialization) async throws

    /// Applies fetched records and deletions in one local transaction.
    func applyFetchedChanges(
        records: [CKRecord],
        deletedRecordIDs: [CKRecord.ID]
    ) async throws

    /// Applies fetched custom-zone deletions to the local store.
    func applyDeletedZones(_ zoneIDs: [CKRecordZone.ID]) async throws

    /// Persists the server system fields returned for successfully saved records.
    func didSave(records: [CKRecord]) async throws

    /// Marks record deletions as successfully synchronized.
    func didDelete(recordIDs: [CKRecord.ID]) async throws

    /// Removes stale server system fields before recreating a missing remote record.
    func clearServerRecord(for recordID: CKRecord.ID) async throws

    /// Reconciles an application-semantic record conflict.
    func resolve(conflict: CloudSaveConflict) async throws -> CloudSaveConflictResolution

    /// Persists a merged conflict record before the engine retries it.
    func persistResolvedRecord(_ record: CKRecord) async throws

    /// Updates local account-scoped persistence after an iCloud account change.
    func handle(accountChange: CloudSaveAccountChange) async throws

    /// Records a failure that requires application attention.
    func handle(failure: CloudSaveFailure, recordID: CKRecord.ID?) async
}
