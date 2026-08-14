import Foundation

/// Combines one durable host-ledger snapshot with mutations that raced with its asynchronous read.
struct CloudSavePendingChangesSnapshot: Sendable {
    /// The authoritative pending changes returned by the host.
    let durableChanges: [CloudSavePendingChange]

    /// Ledger mutations committed after the host-ledger read began, in their original order.
    let subsequentMutations: [CloudSaveLedgerMutation]
}

// MARK: - Effective Changes

extension CloudSavePendingChangesSnapshot {
    /// Returns whether reconciliation leaves one exact change pending.
    func containsEffectiveChange(_ expectedChange: CloudSavePendingChange) -> Bool {
        var effectiveChange = durableChanges.last {
            $0.recordID == expectedChange.recordID
        }

        for mutation in subsequentMutations {
            switch mutation {
            case .enqueue(let change) where change.recordID == expectedChange.recordID:
                effectiveChange = change
            case .remove(let change) where effectiveChange == change:
                effectiveChange = nil
            case .enqueue, .remove:
                break
            }
        }

        return effectiveChange == expectedChange
    }
}
