import Foundation

/// Account-bound cloud work is fenced before invalidation is published to the host.
public enum CloudSaveAccountEvent: Equatable, Sendable {
    /// Revoke old cloud authority immediately; local visibility follows the host's authorization policy.
    case invalidated
    /// A revalidation completed; persisted account strings alone do not establish trust.
    case resolved(CloudSaveAccountSnapshot)
}
