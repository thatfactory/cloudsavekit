import CloudKit
import Foundation

@testable import CloudSaveKit

/// Retains an independent durable ledger and suspension points for immutable host-boundary tests.
actor CloudSavePrivateClientMock: CloudSaveClient {
    private var ledger: [CloudSavePendingChange] = []
    private var suspension: CloudSaveTestSuspension?
    private(set) var accountCallbackCount = 0
    private(set) var deletedZoneCallbackCount = 0
    private(set) var appliedRecords: [CKRecord] = []

    /// Represents an explicit local transaction that remains durable while cloud work is paused.
    func commit(_ change: CloudSavePendingChange) { ledger.append(change) }

    /// Holds ledger and record reads to test post-suspension fencing.
    func pauseReads(_ suspension: CloudSaveTestSuspension) { self.suspension = suspension }

    /// Captures the original ledger even if account invalidation occurs during its read.
    func pendingChanges() async -> [CloudSavePendingChange] {
        let changes = ledger
        await suspension?.suspend()
        return changes
    }

    /// Creates a neutral record for the original store's pending mutation.
    func record(for recordID: CKRecord.ID) async -> CKRecord? {
        await suspension?.suspend()
        return CKRecord(recordType: "Note", recordID: recordID)
    }

    /// Satisfies opaque checkpoint persistence for this in-memory client fixture.
    func persist(stateSerialization: CKSyncEngine.State.Serialization) {}

    /// Captures downloaded records without replacing the fixture's durable local ledger.
    func applyFetchedChanges(records: [CKRecord], deletedRecordIDs: [CKRecord.ID]) { appliedRecords += records }

    /// Counts the destructive callback that personal sessions must never invoke.
    func applyDeletedZones(_ zoneIDs: [CKRecordZone.ID]) { deletedZoneCallbackCount += 1 }

    /// Keeps acknowledgements irrelevant to the session-isolation fixture.
    func didSave(records: [CKRecord]) {}

    /// Keeps acknowledgements irrelevant to the session-isolation fixture.
    func didDelete(recordIDs: [CKRecord.ID]) {}

    /// Keeps server metadata irrelevant to the session-isolation fixture.
    func clearServerRecord(for recordID: CKRecord.ID) {}

    /// Preserves application ownership of merge decisions in the neutral fixture.
    func resolve(conflict: CloudSaveConflict) -> CloudSaveConflictResolution { .requiresUserDecision }

    /// Keeps conflict persistence irrelevant to the session-isolation fixture.
    func persistResolvedRecord(_ record: CKRecord) {}

    /// Detects accidental use of the legacy mutable-account host callback.
    func handle(accountChange: CloudSaveAccountChange) { accountCallbackCount += 1 }

    /// Keeps diagnostics outside the test's stored domain data.
    func handle(failure: CloudSaveFailure, recordID: CKRecord.ID?) {}
}
