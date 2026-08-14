import Foundation

/// Describes the current observable state of a cloud-save engine.
public enum CloudSaveStatus: Equatable, Sendable {
    /// The engine has not started yet.
    case idle

    /// The engine is fetching remote changes.
    case fetching

    /// The engine is sending locally pending changes.
    case sending

    /// The local store is ready and may still have pending uploads.
    case ready(hasPendingChanges: Bool)

    /// Synchronization needs application attention.
    case failed(CloudSaveFailure)
}
