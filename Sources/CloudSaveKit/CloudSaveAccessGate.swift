import Foundation
import Synchronization

/// Synchronously fences asynchronous operations before teardown or host notification can suspend.
final class CloudSaveAccessGate: Sendable {
    private let state = Mutex(State())
    private let onDrainWait: @Sendable () -> Void

    /// Allows deterministic observation of an admitted callback drain without timing-based tests.
    init(onDrainWait: @escaping @Sendable () -> Void = {}) {
        self.onDrainWait = onDrainWait
    }

    /// Rejects access after the first terminal transition.
    func check() throws {
        if let error = state.withLock({ $0.failure }) {
            throw error
        }
    }

    /// Closes this generation permanently, retaining its first terminal reason.
    @discardableResult
    func close(_ error: CloudSavePrivateError = .sessionInvalidated) -> Bool {
        state.withLock {
            guard $0.failure == nil else {
                return false
            }
            $0.failure = error
            return true
        }
    }

    /// Atomically admits a host callback so closing and draining cannot miss an in-flight write.
    func beginCallback() throws {
        try state.withLock {
            if let failure = $0.failure { throw failure }
            $0.callbacks += 1
        }
    }

    /// Releases an admitted callback only after the host's asynchronous operation has returned.
    func endCallback() {
        let waiters = state.withLock { state in
            state.callbacks -= 1
            guard state.callbacks == 0 else { return [CheckedContinuation<Void, Never>]() }
            defer { state.waiters.removeAll() }
            return state.waiters
        }
        for waiter in waiters { waiter.resume() }
    }

    /// After closure, waits for host callbacks independently of CloudKit operation cancellation.
    func waitForCallbacks() async {
        await withCheckedContinuation { continuation in
            let finished = state.withLock { state in
                guard state.callbacks > 0 else { return true }
                state.waiters.append(continuation)
                return false
            }
            if finished {
                continuation.resume()
            } else {
                onDrainWait()
            }
        }
    }

    private struct State {
        var failure: CloudSavePrivateError?
        var callbacks = 0
        var waiters: [CheckedContinuation<Void, Never>] = []
    }
}
