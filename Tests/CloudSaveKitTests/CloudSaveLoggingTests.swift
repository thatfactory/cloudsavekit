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

    @Test func formatsFetchDiagnosticsWithoutCloudKitIdentities() {
        #expect(
            CloudSaveLogging.fetchState(phase: "before", configuredZoneDirty: true)
                == "fetch state | phase=before, configured-zone-dirty=true"
        )
        #expect(
            CloudSaveLogging.fetchedDatabaseChanges(
                modifications: 2,
                deletions: 1,
                configuredZoneChanged: true
            ) == "fetch database | modifications=2, deletions=1, configured-zone-changed=true"
        )
        #expect(
            CloudSaveLogging.fetchedConfiguredZoneChanges(modifications: 3, deletions: 1)
                == "fetch zone | phase=changes, modifications=3, deletions=1"
        )
    }
}
