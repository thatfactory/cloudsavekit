import Foundation

/// A current account identity verified by one coordinator, never reconstructed from persisted text.
public struct CloudSaveVerifiedAccount: Hashable, Sendable {
    /// An opaque CloudKit identity suitable for private local-store provenance, never logging.
    public let recordName: String
    let coordinatorID: UUID
    let generation: UUID
}
