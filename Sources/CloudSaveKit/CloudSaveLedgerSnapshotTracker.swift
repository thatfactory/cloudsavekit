import CloudKit
import Foundation

/// Retains ordered enqueues that occur while the host produces a durable-ledger snapshot.
struct CloudSaveLedgerSnapshotTracker: Sendable {
    private var activeSnapshots: [Snapshot] = []
    private var ledgerMutations: [TrackedMutation] = []
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

    /// Records pending changes in the exact order in which the engine receives them.
    mutating func recordEnqueues(_ changes: [CloudSavePendingChange]) {
        record(changes.map(CloudSaveLedgerMutation.enqueue))
    }

    /// Records removed pending changes in the exact order in which the host commits them.
    mutating func recordRemovals(_ changes: [CloudSavePendingChange]) {
        record(changes.map(CloudSaveLedgerMutation.remove))
    }

    /// Completes a snapshot and returns ledger mutations committed after its read began.
    mutating func completeSnapshot(_ snapshot: Snapshot) -> [CloudSaveLedgerMutation] {
        guard remove(snapshot) else {
            return []
        }

        let mutations: [CloudSaveLedgerMutation] = ledgerMutations.compactMap { trackedMutation in
            guard trackedMutation.generation > snapshot.generation else {
                return nil
            }

            return trackedMutation.mutation
        }
        pruneMutationsNoLongerNeeded()
        return mutations
    }

    /// Cancels a snapshot without replaying its concurrent ledger mutations.
    mutating func cancelSnapshot(_ snapshot: Snapshot) {
        guard remove(snapshot) else {
            return
        }

        pruneMutationsNoLongerNeeded()
    }
}

// MARK: - Snapshot

extension CloudSaveLedgerSnapshotTracker {
    /// Identifies the ledger generation visible when one host-ledger read begins.
    struct Snapshot: Equatable, Sendable {
        fileprivate let generation: Int
        fileprivate let identifier: Int
    }
}

// MARK: - Private

extension CloudSaveLedgerSnapshotTracker {
    /// Associates one ordered ledger mutation with its generation.
    private struct TrackedMutation: Sendable {
        let generation: Int
        let mutation: CloudSaveLedgerMutation
    }

    /// Records ledger mutations only while at least one asynchronous snapshot is suspended.
    private mutating func record(_ mutations: [CloudSaveLedgerMutation]) {
        guard !activeSnapshots.isEmpty else {
            return
        }

        for mutation in mutations {
            latestGeneration &+= 1
            ledgerMutations.append(
                TrackedMutation(
                    generation: latestGeneration,
                    mutation: mutation
                )
            )
        }
    }

    /// Removes one active snapshot if it is still tracked.
    private mutating func remove(_ snapshot: Snapshot) -> Bool {
        guard let index = activeSnapshots.firstIndex(of: snapshot) else {
            return false
        }

        activeSnapshots.remove(at: index)
        return true
    }

    /// Discards mutations that every remaining host-ledger snapshot already includes.
    private mutating func pruneMutationsNoLongerNeeded() {
        guard let oldestGeneration = activeSnapshots.map(\.generation).min() else {
            ledgerMutations.removeAll(keepingCapacity: true)
            return
        }

        ledgerMutations.removeAll { trackedMutation in
            trackedMutation.generation <= oldestGeneration
        }
    }
}
