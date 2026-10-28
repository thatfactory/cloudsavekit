import CloudKit
import Foundation

/// Retains server retry timing across manual requests without creating another sync scheduler.
actor CloudSavePrivateRequestGate {
    private let now: @Sendable () -> ContinuousClock.Instant
    private let sleep: @Sendable (Duration) async throws -> Void
    private var nextRequest: ContinuousClock.Instant?

    /// Allows deterministic retry tests without wall-clock sleeps.
    init(
        now: @escaping @Sendable () -> ContinuousClock.Instant = { .now },
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.now = now
        self.sleep = sleep
    }

    /// Waits out a server throttle and checks lifecycle both before and after transport suspension.
    func perform<Value: Sendable>(
        validate: @Sendable () throws -> Void,
        operation: @Sendable () async throws -> Value
    ) async throws -> Value {
        try Task.checkCancellation()
        try validate()
        while let nextRequest, nextRequest > now() {
            try await sleep(now().duration(to: nextRequest))
            try Task.checkCancellation()
            try validate()
        }
        try Task.checkCancellation()
        try validate()
        do {
            let value = try await operation()
            try Task.checkCancellation()
            try validate()
            return value
        } catch {
            try validate()
            if let delay = (error as? CKError)?.retryAfterSeconds, delay.isFinite, delay > 0 {
                let deadline = now().advanced(by: .seconds(delay))
                nextRequest = max(nextRequest ?? deadline, deadline)
            }
            throw error
        }
    }
}
