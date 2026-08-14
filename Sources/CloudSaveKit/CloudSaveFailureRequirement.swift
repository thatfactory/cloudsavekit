import Foundation

/// Retains one attention-required failure until its exact recovery condition is satisfied.
struct CloudSaveFailureRequirement: Equatable, Sendable {
    /// The work item that failed.
    let context: CloudSaveFailureContext

    /// The privacy-safe failure reported to the host.
    let failure: CloudSaveFailure

    /// The first operation generation allowed to clear an operation failure.
    let minimumRecoveryGeneration: Int?
}
