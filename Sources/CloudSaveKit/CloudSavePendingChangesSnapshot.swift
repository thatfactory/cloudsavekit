import Foundation

/// Combines one durable host-ledger snapshot with enqueues that raced with its asynchronous read.
struct CloudSavePendingChangesSnapshot: Sendable {
    /// The authoritative pending changes returned by the host.
    let durableChanges: [CloudSavePendingChange]

    /// Changes enqueued after the host-ledger read began, in their original order.
    let subsequentlyEnqueuedChanges: [CloudSavePendingChange]
}
