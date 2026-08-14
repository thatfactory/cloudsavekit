import Foundation

/// Serializes asynchronous operations without blocking their executor.
actor CloudSaveAsyncLock {
    private var isLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Runs one operation after every previously submitted operation completes.
    func withLock<Result: Sendable>(
        _ operation: @Sendable () async throws -> Result
    ) async rethrows -> Result {
        await acquire()

        do {
            let result = try await operation()
            release()
            return result
        } catch {
            release()
            throw error
        }
    }
}

// MARK: - Private

extension CloudSaveAsyncLock {
    /// Acquires the lock immediately or suspends behind earlier callers.
    private func acquire() async {
        guard isLocked else {
            isLocked = true
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    /// Transfers ownership to the oldest waiter or makes the lock available.
    private func release() {
        guard !waiters.isEmpty else {
            isLocked = false
            return
        }

        waiters.removeFirst().resume()
    }
}
