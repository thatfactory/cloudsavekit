import Foundation

/// Identifies a synchronization operation tracked by the state machine.
enum CloudSaveOperation: Hashable, Sendable {
    /// Fetches remote CloudKit changes.
    case fetching

    /// Sends locally durable CloudKit changes.
    case sending

    /// The public status reported while this operation is in progress.
    var status: CloudSaveStatus {
        switch self {
        case .fetching:
            .fetching
        case .sending:
            .sending
        }
    }
}
