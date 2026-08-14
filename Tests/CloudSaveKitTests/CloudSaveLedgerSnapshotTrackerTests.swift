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
        tracker.recordEnqueues(expectedChanges)

        #expect(
            tracker.completeSnapshot(snapshot)
                == expectedChanges.map(CloudSaveLedgerMutation.enqueue)
        )
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
        tracker.recordEnqueues([firstChange])
        let laterSnapshot = tracker.beginSnapshot()
        tracker.recordEnqueues([secondChange])

        #expect(tracker.completeSnapshot(laterSnapshot) == [.enqueue(secondChange)])
        #expect(
            tracker.completeSnapshot(earlierSnapshot)
                == [.enqueue(firstChange), .enqueue(secondChange)]
        )
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
        tracker.recordEnqueues([firstChange])
        let laterSnapshot = tracker.beginSnapshot()
        tracker.recordEnqueues([secondChange])

        #expect(
            tracker.completeSnapshot(earlierSnapshot)
                == [.enqueue(firstChange), .enqueue(secondChange)]
        )
        #expect(tracker.completeSnapshot(laterSnapshot) == [.enqueue(secondChange)])
    }

    @Test("Does not retain enqueues when no ledger read is suspended")
    func ignoresEnqueuesOutsideSnapshot() {
        let change = CloudSavePendingChange.save(
            Self.makeRecordID(named: "save")
        )
        var tracker = CloudSaveLedgerSnapshotTracker()

        tracker.recordEnqueues([change])
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
        tracker.recordEnqueues([change])
        tracker.cancelSnapshot(cancelledSnapshot)

        #expect(tracker.completeSnapshot(earlierSnapshot) == [.enqueue(change)])
    }

    @Test("Preserves acknowledgements that race with a ledger read")
    func preservesConcurrentAcknowledgements() {
        let recordID = Self.makeRecordID(named: "acknowledged")
        var tracker = CloudSaveLedgerSnapshotTracker()

        let snapshot = tracker.beginSnapshot()
        tracker.recordRemovals([.save(recordID)])

        #expect(tracker.completeSnapshot(snapshot) == [.remove(.save(recordID))])
    }

    @Test("Preserves enqueue and explicit removal order for one record")
    func preservesMutationOrder() {
        let recordID = Self.makeRecordID(named: "ordered")
        let change = CloudSavePendingChange.save(recordID)
        var tracker = CloudSaveLedgerSnapshotTracker()

        let snapshot = tracker.beginSnapshot()
        tracker.recordEnqueues([change])
        tracker.recordRemovals([change])

        #expect(
            tracker.completeSnapshot(snapshot)
                == [.enqueue(change), .remove(change)]
        )
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
