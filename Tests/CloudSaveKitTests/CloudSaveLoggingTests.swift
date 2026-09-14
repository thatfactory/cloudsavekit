import Testing

@testable import CloudSaveKit

@Suite("Cloud save logging")
struct CloudSaveLoggingTests {
    @Test func formatsFreshnessRequestWithoutCloudKitIdentities() {
        let body = CloudSaveLogging.fetchRequest(
            request: 12,
            requiredFetch: 31,
            waitedForPriorFetch: true
        )

        #expect(
            CloudSaveLogging.formatted(body)
                == "☁️ fetch request | request=12, required=31, waited=true"
        )
    }

    @Test func formatsFetchGenerationTransitions() {
        #expect(
            CloudSaveLogging.formatted(CloudSaveLogging.fetchGeneration(31, phase: "started"))
                == "☁️ fetch generation | generation=31, phase=started"
        )
        #expect(
            CloudSaveLogging.formatted(CloudSaveLogging.fetchGeneration(31, phase: "completed"))
                == "☁️ fetch generation | generation=31, phase=completed"
        )
    }

    @Test func formatsSuccessfulRequestCompletion() {
        #expect(
            CloudSaveLogging.formatted(CloudSaveLogging.fetchRequestSucceeded(request: 12))
                == "☁️ fetch request | request=12, result=success"
        )
    }
}
