import Foundation

/// Describes a lifecycle error raised before CloudKit synchronization can begin.
public enum CloudSaveEngineError: Error, Equatable, Sendable {
    /// The engine has not been started successfully.
    case notStarted

    /// A host persistence callback failed and the host must recover before restarting the engine.
    case hostRecoveryRequired
}
