import CloudKit

/// Describes an ordered host-ledger mutation that can race with an asynchronous snapshot.
enum CloudSaveLedgerMutation: Equatable, Sendable {
    /// Adds or replaces one durable pending change.
    case enqueue(CloudSavePendingChange)

    /// Removes one exact durable pending change after acknowledgement or local disappearance.
    case remove(CloudSavePendingChange)
}
