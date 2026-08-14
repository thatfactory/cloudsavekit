import CloudKit
import Testing

@testable import CloudSaveKit

@Suite("Cloud save pending-change snapshot")
struct CloudSavePendingChangesSnapshotTests {
    @Test("Retains a newer save with the same record identity")
    func retainsNewerSave() {
        let save = CloudSavePendingChange.save(
            Self.makeRecordID(named: "edited-during-upload")
        )
        let snapshot = CloudSavePendingChangesSnapshot(
            durableChanges: [],
            subsequentMutations: [.enqueue(save)]
        )

        #expect(snapshot.containsEffectiveChange(save))
    }

    @Test("Recognizes a completed save absent from the current ledger")
    func recognizesCompletedSave() {
        let save = CloudSavePendingChange.save(
            Self.makeRecordID(named: "completed")
        )
        let snapshot = CloudSavePendingChangesSnapshot(
            durableChanges: [save],
            subsequentMutations: [.remove(save)]
        )

        #expect(!snapshot.containsEffectiveChange(save))
    }

    @Test("Does not let an old save acknowledgement erase a newer deletion")
    func preservesNewerDeletion() {
        let recordID = Self.makeRecordID(named: "deleted-during-upload")
        let save = CloudSavePendingChange.save(recordID)
        let delete = CloudSavePendingChange.delete(recordID)
        let snapshot = CloudSavePendingChangesSnapshot(
            durableChanges: [save],
            subsequentMutations: [
                .enqueue(delete),
                .remove(save),
            ]
        )

        #expect(!snapshot.containsEffectiveChange(save))
        #expect(snapshot.containsEffectiveChange(delete))
    }
}

// MARK: - Private

extension CloudSavePendingChangesSnapshotTests {
    /// The custom zone used by pending-change snapshot record identifiers.
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
