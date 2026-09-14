import Foundation

/// Classifies the one account-establishment event that belongs to a nil-state engine bootstrap.
struct CloudSaveAccountTransitionClassifier {
    private let wasInitializedWithState: Bool
    private var hasObservedAccountChange: Bool

    /// Creates lifecycle classification for one CKSyncEngine instance.
    init(wasInitializedWithState: Bool) {
        self.wasInitializedWithState = wasInitializedWithState
        hasObservedAccountChange = wasInitializedWithState
    }

    /// Returns whether this account event must invalidate in-flight explicit operations.
    mutating func shouldInvalidate(for accountChange: CloudSaveAccountChange) -> Bool {
        let isInitialSignIn =
            !wasInitializedWithState
            && !hasObservedAccountChange
            && accountChange.isSignedIn
        hasObservedAccountChange = true
        return !isInitialSignIn
    }
}
