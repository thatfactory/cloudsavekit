import Foundation

/// Account-bound cloud work is fenced before invalidation is published to the host.
public enum CloudSaveAccountEvent: Equatable, Sendable {
    /// Hide old account content before awaiting local or cloud teardown.
    case invalidated
    /// A revalidation completed; persisted account strings alone do not establish trust.
    case resolved(CloudSaveAccountSnapshot)
}
