import CloudKit

/// Permanently binds callbacks to one host store and rejects work after session revocation.
struct CloudSavePrivateClient: CloudSaveClient {
    let client: any CloudSaveClient
    let context: CloudSavePrivateSessionContext

    /// Reads only the original store's ledger and fences results that crossed invalidation.
    func pendingChanges() async throws -> [CloudSavePendingChange] {
        try context.check()
        let changes = try await client.pendingChanges()
        try context.validatePending(changes)
        return changes
    }

    /// Rejects stale record materialization before it can enter another account's cloud queue.
    func record(for recordID: CKRecord.ID) async throws -> CKRecord? {
        try context.check()
        let record = try await client.record(for: recordID)
        try context.check()
        return record
    }

    /// Persists only a checkpoint admitted by this session's gate.
    func persist(stateSerialization: CKSyncEngine.State.Serialization) async throws {
        try context.check()
        try await client.persist(stateSerialization: stateSerialization)
        try context.check()
    }

    /// A callback already admitted may finish in its original store, never a replacement store.
    func applyFetchedChanges(records: [CKRecord], deletedRecordIDs: [CKRecord.ID]) async throws {
        try context.check()
        guard !deletedRecordIDs.contains(context.manifestRecordID) else {
            throw CloudSavePrivateError.missingTrustedManifest
        }
        try await client.applyFetchedChanges(records: records, deletedRecordIDs: deletedRecordIDs)
        try context.check()
    }

    /// A missing trusted zone requires recovery without destructive host clearing.
    func applyDeletedZones(_ zoneIDs: [CKRecordZone.ID]) async throws {
        throw CloudSavePrivateError.missingTrustedManifest
    }

    /// Acknowledges uploads only in the original immutable store.
    func didSave(records: [CKRecord]) async throws {
        try context.check()
        try await client.didSave(records: records)
        try context.check()
    }

    /// Acknowledges deletions only in the original immutable store.
    func didDelete(recordIDs: [CKRecord.ID]) async throws {
        try context.check()
        try await client.didDelete(recordIDs: recordIDs)
        try context.check()
    }

    /// Clears record metadata only for the existing verified zone.
    func clearServerRecord(for recordID: CKRecord.ID) async throws {
        try context.check()
        try await client.clearServerRecord(for: recordID)
        try context.check()
    }

    /// Keeps application merge policy in the original host persistence boundary.
    func resolve(conflict: CloudSaveConflict) async throws -> CloudSaveConflictResolution {
        try context.check()
        let resolution = try await client.resolve(conflict: conflict)
        try context.check()
        return resolution
    }

    /// Commits a merged value before admitting its retry.
    func persistResolvedRecord(_ record: CKRecord) async throws {
        try context.check()
        try await client.persistResolvedRecord(record)
        try context.check()
    }

    /// Fixed sessions never ask a mutable host callback to select another account's store.
    func handle(accountChange: CloudSaveAccountChange) throws {
        try context.validate(accountChange)
    }

    /// Discards diagnostics from a retired session rather than publishing into new host state.
    func handle(failure: CloudSaveFailure, recordID: CKRecord.ID?) async {
        guard (try? context.check()) != nil else {
            return
        }
        await client.handle(failure: failure, recordID: recordID)
    }
}
