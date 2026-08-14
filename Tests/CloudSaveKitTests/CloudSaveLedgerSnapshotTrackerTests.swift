import CloudKit
import Testing

@testable import CloudSaveKit

@Suite("Cloud save ledger snapshot tracker")
struct CloudSaveLedgerSnapshotTrackerTests {
    @Test("Replays changes enqueued after a ledger read begins in order")
    func replaysConcurrentEnqueuesInOrder() {
        let firstRecordID = Self.makeRecordID(named: "first")
        let secondRecordID = Self.makeRecordID(named: "second")
        let expectedChanges: [CloudSavePendingChange] = [
            .delete(firstRecordID),
            .save(firstRecordID),
            .save(secondRecordID),
        ]
        var tracker = CloudSaveLedgerSnapshotTracker()

        let snapshot = tracker.beginSnapshot()
        tracker.record(expectedChanges)

        #expect(tracker.completeSnapshot(snapshot) == expectedChanges)
    }

    @Test("Preserves the suffix required by every overlapping ledger read")
    func preservesChangesForOverlappingSnapshots() {
        let firstChange = CloudSavePendingChange.delete(
            Self.makeRecordID(named: "first")
        )
        let secondChange = CloudSavePendingChange.save(
            Self.makeRecordID(named: "second")
        )
        var tracker = CloudSaveLedgerSnapshotTracker()

        let earlierSnapshot = tracker.beginSnapshot()
        tracker.record([firstChange])
        let laterSnapshot = tracker.beginSnapshot()
        tracker.record([secondChange])

        #expect(tracker.completeSnapshot(laterSnapshot) == [secondChange])
        #expect(tracker.completeSnapshot(earlierSnapshot) == [firstChange, secondChange])
    }

    @Test("Completing an older ledger read retains the suffix needed by a newer read")
    func completesOverlappingSnapshotsInEitherOrder() {
        let firstChange = CloudSavePendingChange.delete(
            Self.makeRecordID(named: "first")
        )
        let secondChange = CloudSavePendingChange.save(
            Self.makeRecordID(named: "second")
        )
        var tracker = CloudSaveLedgerSnapshotTracker()

        let earlierSnapshot = tracker.beginSnapshot()
        tracker.record([firstChange])
        let laterSnapshot = tracker.beginSnapshot()
        tracker.record([secondChange])

        #expect(tracker.completeSnapshot(earlierSnapshot) == [firstChange, secondChange])
        #expect(tracker.completeSnapshot(laterSnapshot) == [secondChange])
    }

    @Test("Does not retain enqueues when no ledger read is suspended")
    func ignoresEnqueuesOutsideSnapshot() {
        let change = CloudSavePendingChange.save(
            Self.makeRecordID(named: "save")
        )
        var tracker = CloudSaveLedgerSnapshotTracker()

        tracker.record([change])
        let snapshot = tracker.beginSnapshot()

        #expect(tracker.completeSnapshot(snapshot).isEmpty)
    }

    @Test("Cancelling one ledger read keeps changes needed by an older read")
    func cancelsSnapshotsIndependently() {
        let change = CloudSavePendingChange.save(
            Self.makeRecordID(named: "save")
        )
        var tracker = CloudSaveLedgerSnapshotTracker()

        let earlierSnapshot = tracker.beginSnapshot()
        let cancelledSnapshot = tracker.beginSnapshot()
        tracker.record([change])
        tracker.cancelSnapshot(cancelledSnapshot)

        #expect(tracker.completeSnapshot(earlierSnapshot) == [change])
    }
}

// MARK: - Private

extension CloudSaveLedgerSnapshotTrackerTests {
    /// The custom zone used by ledger-snapshot record identifiers.
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
