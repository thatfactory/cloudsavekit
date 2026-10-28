import Foundation
import Synchronization

/// Retains a single CloudKit item result until its enclosing operation has completed.
final class CloudSaveOperationResult<Value: Sendable>: Sendable {
    private let result = Mutex<Result<Value, any Error>?>(nil)

    /// Records the per-item outcome before CloudKit invokes the operation completion.
    func set(_ value: Result<Value, any Error>) {
        result.withLock { $0 = value }
    }

    /// Prefers item errors over aggregate partial failures, without treating missing results as success.
    func finish(_ operationResult: Result<Void, any Error>) throws -> Value {
        let item = result.withLock { $0 }
        if case .failure(let error) = item {
            throw error
        }
        try operationResult.get()
        if let item {
            return try item.get()
        }
        throw CloudSavePrivateError.transport(.unknown(code: 0), retryAfterSeconds: nil)
    }
}
