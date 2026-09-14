import Foundation

/// Coordinates explicit freshness requests with every fetch generation emitted by CKSyncEngine.
actor CloudSaveFetchCoordinator {
    private var activeFetchGenerations: [Int] = []
    private var completedGeneration = 0
    private var fetchGeneration = 0
    private var failedFetchGenerations: Set<Int> = []
    private var idleWaiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var latestSuccessfulFetchGeneration = 0
    private var lifecycleGeneration = 0
    private var requestGeneration = 0

    /// Records an explicit request and waits for fetches that predate it to drain.
    func prepareRequest() async throws -> Request {
        requestGeneration &+= 1
        let request = Request(
            lifecycleGeneration: lifecycleGeneration,
            requestGeneration: requestGeneration,
            requiredFetchGeneration: fetchGeneration &+ 1,
            waitedForPriorFetch: !activeFetchGenerations.isEmpty
        )
        guard !activeFetchGenerations.isEmpty else {
            return request
        }

        try await waitUntilIdle()
        return request
    }

    /// Records a fetch generation regardless of whether it was automatic or explicit.
    @discardableResult
    func beginFetch() -> Int {
        fetchGeneration &+= 1
        activeFetchGenerations.append(fetchGeneration)
        return fetchGeneration
    }

    /// Records one terminal fetch event and releases requests after all older work drains.
    @discardableResult
    func completeFetch() -> Int {
        guard !activeFetchGenerations.isEmpty else {
            return completedGeneration
        }
        let generation = activeFetchGenerations.removeFirst()
        completedGeneration = max(completedGeneration, generation)
        if !failedFetchGenerations.contains(generation) {
            latestSuccessfulFetchGeneration = max(latestSuccessfulFetchGeneration, generation)
        }
        if activeFetchGenerations.isEmpty {
            resumeIdleWaiters()
        }
        return completedGeneration
    }

    /// Marks the active fetch generation as failed for the configured zone.
    func failConfiguredZoneFetch() {
        guard let generation = activeFetchGenerations.first else {
            return
        }
        failedFetchGenerations.insert(generation)
    }

    /// Verifies that a fetch which began no earlier than the request has completed.
    func validate(_ request: Request) throws {
        guard request.lifecycleGeneration == lifecycleGeneration else {
            throw CloudSaveEngineError.hostRecoveryRequired
        }
        if latestSuccessfulFetchGeneration >= request.requiredFetchGeneration {
            return
        }
        guard completedGeneration >= request.requiredFetchGeneration else {
            throw CloudSaveEngineError.freshFetchNotObserved
        }
        throw CloudSaveEngineError.configuredZoneFetchFailed
    }

    /// Invalidates suspended requests when their engine lifecycle ends.
    func invalidate() {
        lifecycleGeneration &+= 1
        activeFetchGenerations.removeAll()
        failedFetchGenerations.removeAll()
        latestSuccessfulFetchGeneration = 0
        let waiters = idleWaiters.values
        idleWaiters.removeAll()
        for waiter in waiters {
            waiter.resume(throwing: CloudSaveEngineError.hostRecoveryRequired)
        }
    }
}

// MARK: - Request

extension CloudSaveFetchCoordinator {
    /// Identifies the minimum qualifying fetch generation for one explicit request.
    struct Request: Equatable, Sendable {
        let lifecycleGeneration: Int
        let requestGeneration: Int
        let requiredFetchGeneration: Int
        let waitedForPriorFetch: Bool
    }
}

// MARK: - Waiting

extension CloudSaveFetchCoordinator {
    /// Suspends until every fetch active before the request has terminated.
    private func waitUntilIdle() async throws {
        let identifier = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                idleWaiters[identifier] = continuation
            }
        } onCancel: {
            Task { await self.cancelWaiter(identifier) }
        }
    }

    /// Removes and cancels one suspended request.
    private func cancelWaiter(_ identifier: UUID) {
        idleWaiters.removeValue(forKey: identifier)?.resume(throwing: CancellationError())
    }

    /// Releases every request waiting for pre-existing work to drain.
    private func resumeIdleWaiters() {
        let waiters = idleWaiters.values
        idleWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }
}
