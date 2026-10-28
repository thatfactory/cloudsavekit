import Foundation
import Synchronization

/// Synchronously fences asynchronous operations before teardown or host notification can suspend.
final class CloudSaveAccessGate: Sendable {
    private let failure = Mutex<CloudSavePrivateError?>(nil)

    /// Rejects access after the first terminal transition.
    func check() throws {
        if let error = failure.withLock({ $0 }) {
            throw error
        }
    }

    /// Closes this generation permanently, retaining its first terminal reason.
    @discardableResult
    func close(_ error: CloudSavePrivateError = .sessionInvalidated) -> Bool {
        failure.withLock {
            guard $0 == nil else {
                return false
            }
            $0 = error
            return true
        }
    }
}
