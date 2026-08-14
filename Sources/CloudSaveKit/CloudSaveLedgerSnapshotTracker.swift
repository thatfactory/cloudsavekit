import Foundation

/// Retains ordered enqueues that occur while the host produces a durable-ledger snapshot.
struct CloudSaveLedgerSnapshotTracker: Sendable {
    private var activeSnapshots: [Snapshot] = []
    private var enqueuedChanges: [EnqueuedChange] = []
    private var latestGeneration = 0
    private var nextIdentifier = 0

    /// Begins tracking changes that can race with one host-ledger read.
    mutating func beginSnapshot() -> Snapshot {
        nextIdentifier &+= 1
        let snapshot = Snapshot(
            generation: latestGeneration,
            identifier: nextIdentifier
        )
        activeSnapshots.append(snapshot)
        return snapshot
    }

    /// Records changes in the exact order in which the engine receives them.
    mutating func record(_ changes: [CloudSavePendingChange]) {
        guard !activeSnapshots.isEmpty else {
            return
        }

        for change in changes {
            latestGeneration &+= 1
            enqueuedChanges.append(
                EnqueuedChange(
                    change: change,
                    generation: latestGeneration
                )
            )
        }
    }

    /// Completes a snapshot and returns changes enqueued after its ledger read began.
    mutating func completeSnapshot(_ snapshot: Snapshot) -> [CloudSavePendingChange] {
        guard remove(snapshot) else {
            return []
        }

        let changes: [CloudSavePendingChange] = enqueuedChanges.compactMap { enqueuedChange in
            guard enqueuedChange.generation > snapshot.generation else {
                return nil
            }

            return enqueuedChange.change
        }
        pruneChangesNoLongerNeeded()
        return changes
    }

    /// Cancels a snapshot without replaying its concurrently enqueued changes.
    mutating func cancelSnapshot(_ snapshot: Snapshot) {
        guard remove(snapshot) else {
            return
        }

        pruneChangesNoLongerNeeded()
    }
}

// MARK: - Snapshot

extension CloudSaveLedgerSnapshotTracker {
    /// Identifies the enqueue generation visible when one host-ledger read begins.
    struct Snapshot: Equatable, Sendable {
        fileprivate let generation: Int
        fileprivate let identifier: Int
    }
}

// MARK: - Private

extension CloudSaveLedgerSnapshotTracker {
    /// Associates one ordered pending change with its enqueue generation.
    private struct EnqueuedChange: Sendable {
        let change: CloudSavePendingChange
        let generation: Int
    }

    /// Removes one active snapshot if it is still tracked.
    private mutating func remove(_ snapshot: Snapshot) -> Bool {
        guard let index = activeSnapshots.firstIndex(of: snapshot) else {
            return false
        }

        activeSnapshots.remove(at: index)
        return true
    }

    /// Discards changes that every remaining host-ledger snapshot already includes.
    private mutating func pruneChangesNoLongerNeeded() {
        guard let oldestGeneration = activeSnapshots.map(\.generation).min() else {
            enqueuedChanges.removeAll(keepingCapacity: true)
            return
        }

        enqueuedChanges.removeAll { enqueuedChange in
            enqueuedChange.generation <= oldestGeneration
        }
    }
}
