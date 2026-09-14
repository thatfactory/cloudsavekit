import Testing

@testable import CloudSaveKit

@Suite("Cloud save fetch coordinator")
struct CloudSaveFetchCoordinatorTests {
    @Test func requestWaitsForPriorFetchAndRequiresLaterGeneration() async throws {
        // Given
        let coordinator = CloudSaveFetchCoordinator()
        #expect(await coordinator.beginFetch() == 1)
        let requestTask = Task { try await coordinator.prepareRequest() }
        await Task.yield()

        // When
        #expect(await coordinator.completeFetch() == 1)
        let request = try await requestTask.value

        // Then
        #expect(request.waitedForPriorFetch)
        #expect(request.requiredFetchGeneration == 2)
        await #expect(throws: CloudSaveEngineError.freshFetchNotObserved) {
            try await coordinator.validate(request)
        }
        #expect(await coordinator.beginFetch() == 2)
        #expect(await coordinator.completeFetch() == 2)
        try await coordinator.validate(request)
    }

    @Test func postRequestAutomaticFetchSatisfiesFreshnessBarrier() async throws {
        // Given
        let coordinator = CloudSaveFetchCoordinator()
        let request = try await coordinator.prepareRequest()

        // When
        #expect(await coordinator.beginFetch() == 1)
        #expect(await coordinator.completeFetch() == 1)

        // Then
        #expect(!request.waitedForPriorFetch)
        try await coordinator.validate(request)
    }

    @Test func overlappingFetchesReleaseWaiterOnlyAfterBothComplete() async throws {
        // Given
        let coordinator = CloudSaveFetchCoordinator()
        #expect(await coordinator.beginFetch() == 1)
        #expect(await coordinator.beginFetch() == 2)
        let requestTask = Task { try await coordinator.prepareRequest() }
        await Task.yield()

        // When
        #expect(await coordinator.completeFetch() == 1)
        await Task.yield()

        // Then
        #expect(!requestTask.isCancelled)
        #expect(await coordinator.completeFetch() == 2)
        let request = try await requestTask.value
        #expect(request.requiredFetchGeneration == 3)
    }

    @Test func lifecycleInvalidationFailsSuspendedRequest() async {
        // Given
        let coordinator = CloudSaveFetchCoordinator()
        _ = await coordinator.beginFetch()
        let requestTask = Task { try await coordinator.prepareRequest() }
        await Task.yield()

        // When
        await coordinator.invalidate()

        // Then
        await #expect(throws: CloudSaveEngineError.hostRecoveryRequired) {
            try await requestTask.value
        }
    }
}
