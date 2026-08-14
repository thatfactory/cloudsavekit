import Foundation

/// Describes a change to the iCloud account available to a cloud-save engine.
public enum CloudSaveAccountChange: Equatable, Sendable {
    /// A person signed in to iCloud.
    case signedIn(currentAccountID: String)

    /// The current person signed out of iCloud.
    case signedOut(previousAccountID: String)

    /// The device switched directly between two iCloud accounts.
    case switched(previousAccountID: String, currentAccountID: String)
}
