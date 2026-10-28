import Foundation

/// The result of resolving the current system context's iCloud account.
public enum CloudSaveAccountSnapshot: Equatable, Sendable {
    case indeterminate
    case noAccount
    case restricted
    case temporarilyUnavailable
    case verified(CloudSaveVerifiedAccount)
}
