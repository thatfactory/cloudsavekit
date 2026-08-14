import Foundation

/// Combines one durable host-ledger snapshot with mutations that raced with its asynchronous read.
struct CloudSavePendingChangesSnapshot: Sendable {
    /// The authoritative pending changes returned by the host.
    let durableChanges: [CloudSavePendingChange]

    /// Ledger mutations committed after the host-ledger read began, in their original order.
    let subsequentMutations: [CloudSaveLedgerMutation]
}
