import CloudKit
import Testing

@testable import CloudSaveKit

@Suite("Cloud save state machine")
struct CloudSaveStateMachineTests {
    @Test("Preserves independent operation failures until each operation recovers")
    func preservesIndependentOperationFailures() {
        var stateMachine = CloudSaveStateMachine()

        stateMachine.fail(
            .quotaExceeded,
            operation: .sending
        )
        stateMachine.fail(
            .configuration,
            operation: .fetching
        )
        #expect(
            stateMachine.status(hasPendingChanges: true) == .failed(.configuration)
        )

        stateMachine.begin(.fetching)
        stateMachine.complete(.fetching)
        #expect(
            stateMachine.status(hasPendingChanges: true) == .failed(.quotaExceeded)
        )

        stateMachine.begin(.sending)
        stateMachine.complete(.sending)
        #expect(
            stateMachine.status(hasPendingChanges: true) == .ready(hasPendingChanges: true)
        )
    }

    @Test("Does not let a failed operation clear itself with its own completion event")
    func requiresLaterOperationGeneration() {
        var stateMachine = CloudSaveStateMachine()

        stateMachine.begin(.sending)
        stateMachine.fail(
            .restricted,
            operation: .sending
        )
        stateMachine.complete(.sending)
        #expect(
            stateMachine.status(hasPendingChanges: false) == .failed(.restricted)
        )

        stateMachine.begin(.sending)
        stateMachine.complete(.sending)
        #expect(
            stateMachine.status(hasPendingChanges: false) == .ready(hasPendingChanges: false)
        )
    }

    @Test("Resolves record failures independently")
    func resolvesRecordFailuresIndependently() {
        let firstRecordID = Self.makeRecordID(named: "first")
        let secondRecordID = Self.makeRecordID(named: "second")
        var stateMachine = CloudSaveStateMachine()

        stateMachine.fail(
            .quotaExceeded,
            context: .record(firstRecordID)
        )
        stateMachine.fail(
            .recordConflict,
            context: .record(secondRecordID)
        )
        stateMachine.resolve(.record(secondRecordID))
        #expect(
            stateMachine.status(hasPendingChanges: true) == .failed(.quotaExceeded)
        )

        stateMachine.resolve(.record(firstRecordID))
        #expect(
            stateMachine.status(hasPendingChanges: true) == .ready(hasPendingChanges: true)
        )
    }

    @Test("Keeps earlier failures after host recovery")
    func keepsEarlierFailureAfterHostRecovery() {
        let recordID = Self.makeRecordID(named: "save")
        var stateMachine = CloudSaveStateMachine()

        stateMachine.fail(
            .recordConflict,
            context: .record(recordID)
        )
        stateMachine.fail(
            .localPersistence,
            context: .hostPersistence
        )
        #expect(stateMachine.requiresHostRecovery)
        #expect(
            stateMachine.status(hasPendingChanges: true) == .failed(.localPersistence)
        )

        stateMachine.resolve(.hostPersistence)
        #expect(!stateMachine.requiresHostRecovery)
        #expect(
            stateMachine.status(hasPendingChanges: true) == .failed(.recordConflict)
        )
    }

    @Test("Drops operation activity when a failed engine stops")
    func resetsStoppedEngineActivity() {
        var stateMachine = CloudSaveStateMachine()

        stateMachine.begin(.fetching)
        stateMachine.begin(.sending)
        stateMachine.fail(
            .localPersistence,
            context: .hostPersistence
        )
        stateMachine.resetActiveOperations()
        stateMachine.resolve(.hostPersistence)

        #expect(
            stateMachine.status(hasPendingChanges: false) == .ready(hasPendingChanges: false)
        )
    }

    @Test("Reconciles record failures against the host durable ledger")
    func reconcilesRecordFailures() {
        let retainedRecordID = Self.makeRecordID(named: "retained")
        let discardedRecordID = Self.makeRecordID(named: "discarded")
        var stateMachine = CloudSaveStateMachine()

        stateMachine.fail(
            .quotaExceeded,
            context: .record(retainedRecordID)
        )
        stateMachine.fail(
            .recordConflict,
            context: .record(discardedRecordID)
        )
        stateMachine.reconcilePendingRecordIDs(
            [retainedRecordID],
            in: Self.zoneID
        )

        #expect(
            stateMachine.status(hasPendingChanges: true) == .failed(.quotaExceeded)
        )
        stateMachine.resolve(.record(retainedRecordID))
        #expect(
            stateMachine.status(hasPendingChanges: false) == .ready(hasPendingChanges: false)
        )
    }

    @Test("Preserves operation progress until every overlapping operation completes")
    func preservesOverlappingOperationProgress() {
        var stateMachine = CloudSaveStateMachine()

        stateMachine.begin(.fetching)
        stateMachine.begin(.fetching)
        stateMachine.begin(.sending)
        #expect(stateMachine.status(hasPendingChanges: false) == .sending)

        stateMachine.complete(.sending)
        #expect(stateMachine.status(hasPendingChanges: false) == .fetching)

        stateMachine.complete(.fetching)
        #expect(stateMachine.status(hasPendingChanges: false) == .fetching)

        stateMachine.complete(.fetching)
        #expect(
            stateMachine.status(hasPendingChanges: false) == .ready(hasPendingChanges: false)
        )
    }

    @Test("Resolves a zone failure only when that zone succeeds")
    func resolvesZoneFailureIndependently() {
        let unrelatedZoneID = CKRecordZone.ID(
            zoneName: "Unrelated",
            ownerName: CKCurrentUserDefaultName
        )
        var stateMachine = CloudSaveStateMachine()

        stateMachine.fail(
            .zoneUnavailable,
            context: .zone(Self.zoneID)
        )
        stateMachine.resolve(zoneIDs: [unrelatedZoneID])
        #expect(stateMachine.requiresRecovery(for: Self.zoneID))

        stateMachine.resolve(zoneIDs: [Self.zoneID])
        #expect(!stateMachine.requiresRecovery(for: Self.zoneID))
    }

    @Test("Replaces a repeated failure for the same work item")
    func replacesRepeatedFailureForSameContext() {
        let recordID = Self.makeRecordID(named: "save")
        var stateMachine = CloudSaveStateMachine()

        stateMachine.fail(
            .quotaExceeded,
            context: .record(recordID)
        )
        stateMachine.fail(
            .restricted,
            context: .record(recordID)
        )
        #expect(
            stateMachine.status(hasPendingChanges: true) == .failed(.restricted)
        )

        stateMachine.resolve(.record(recordID))
        #expect(
            stateMachine.status(hasPendingChanges: false) == .ready(hasPendingChanges: false)
        )
    }
}

// MARK: - Private

extension CloudSaveStateMachineTests {
    /// The custom zone used by state-machine record identifiers.
    private static var zoneID: CKRecordZone.ID {
        CKRecordZone.ID(
            zoneName: "CloudSaveKitTests",
            ownerName: CKCurrentUserDefaultName
        )
    }

    /// Creates a deterministic record identifier in the test zone.
    private static func makeRecordID(named name: String) -> CKRecord.ID {
        CKRecord.ID(
            recordName: name,
            zoneID: zoneID
        )
    }
}
