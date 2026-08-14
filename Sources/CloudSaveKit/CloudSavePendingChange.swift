import CloudKit

/// Describes one locally durable CloudKit change waiting to be sent.
public enum CloudSavePendingChange: Hashable, Sendable {
    /// Saves or replaces the record with the specified identifier.
    case save(CKRecord.ID)

    /// Deletes the record with the specified identifier.
    case delete(CKRecord.ID)
}
