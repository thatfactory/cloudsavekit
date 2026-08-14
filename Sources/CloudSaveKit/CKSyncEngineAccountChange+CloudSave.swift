import CloudKit

extension CKSyncEngine.Event.AccountChange {
    /// A known, non-destructive account transition suitable for the host boundary.
    var cloudSaveAccountChange: CloudSaveAccountChange? {
        switch changeType {
        case .signIn(let currentUser):
            .signedIn(
                currentAccountID: currentUser.recordName
            )
        case .signOut(let previousUser):
            .signedOut(
                previousAccountID: previousUser.recordName
            )
        case .switchAccounts(let previousUser, let currentUser):
            .switched(
                previousAccountID: previousUser.recordName,
                currentAccountID: currentUser.recordName
            )
        @unknown default:
            nil
        }
    }
}
