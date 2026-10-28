import CloudKit
import Foundation
import Testing

@testable import CloudSaveKit

/// Exercises the policies used by production event handling and host callback admission.
struct CloudSavePrivateIntegrityTests {
    @Test func unchangedManifestIsAppliedButChangedIdentityFencesTheWholeBatch() async throws {
        let (context, coordinator) = try await context()
        defer { withExtendedLifetime(coordinator) {} }
        let host = CloudSavePrivateClientMock()
        let client = CloudSavePrivateClient(client: host, context: context)
        let unchanged = CloudSaveManifestFixture.record(identity: 7)
        try await client.applyFetchedChanges(records: [unchanged], deletedRecordIDs: [])
        #expect(await host.appliedRecords.count == 1)
        let domain = CKRecord(recordType: "Note", recordID: noteID)
        await #expect(throws: CloudSavePrivateError.manifestIdentityMismatch) {
            try await client.applyFetchedChanges(
                records: [domain, CloudSaveManifestFixture.record(identity: 8)], deletedRecordIDs: [])
        }
        #expect(await host.appliedRecords.count == 1)
        #expect(throws: CloudSavePrivateError.manifestIdentityMismatch) {
            try context.validatePending([.save(noteID)])
        }
    }

    @Test func malformedManifestFencesDomainApplyAndPendingSend() async throws {
        let (context, coordinator) = try await context()
        defer { withExtendedLifetime(coordinator) {} }
        let host = CloudSavePrivateClientMock()
        let client = CloudSavePrivateClient(client: host, context: context)
        let malformed = CKRecord(recordType: "NotebookManifest", recordID: CloudSaveManifestFixture.recordID)
        await #expect(throws: CloudSavePrivateError.malformedManifest) {
            try await client.applyFetchedChanges(records: [malformed], deletedRecordIDs: [])
        }
        let engine = CloudSaveSessionEngineMock(client: client)
        let session = CloudSavePrivateSession(
            context: context, engine: engine, transport: CloudSavePrivateTransportMock())
        await #expect(throws: CloudSavePrivateError.malformedManifest) { try await session.sendNow() }
        #expect(await host.appliedRecords.isEmpty)
        #expect(await engine.sendCount == 0)
    }

    @Test func deletedManifestUsesSameEventPolicyAndNeverAppliesDomainData() async throws {
        let (context, coordinator) = try await context()
        defer { withExtendedLifetime(coordinator) {} }
        #expect(throws: CloudSavePrivateError.missingTrustedManifest) {
            try context.validateFetchedChanges(records: [], deletedRecordIDs: [CloudSaveManifestFixture.recordID])
        }
        #expect(throws: CloudSavePrivateError.missingTrustedManifest) { try context.check() }
    }

    @Test func privateFetchRetainsNetworkFailureWhileGenericFetchKeepsItsExistingError() async throws {
        let fetches = CloudSaveFetchCoordinator()
        let request = try await fetches.prepareRequest()
        await fetches.beginFetch()
        await fetches.failConfiguredZoneFetch(error: CKError(.networkUnavailable))
        await fetches.completeFetch()
        do {
            try await fetches.validate(request, preservingTransportError: true)
            Issue.record("Configured-zone network failure must fail the fetch barrier.")
        } catch {
            let normalized = CloudSavePrivateError.normalize(error) as? CloudSavePrivateError
            #expect(normalized == .transport(.networkUnavailable, retryAfterSeconds: nil))
            #expect(normalized?.permitsOfflineUse == true)
        }
        await #expect(throws: CloudSaveEngineError.configuredZoneFetchFailed) { try await fetches.validate(request) }
        #expect(
            CloudSavePrivateError.normalize(CloudSaveEngineError.hostRecoveryRequired) as? CloudSavePrivateError
                == .hostRecoveryRequired)
        #expect(
            CloudSavePrivateError.normalize(CloudSaveEngineError.freshFetchNotObserved) as? CloudSavePrivateError
                == .fetchIncomplete)
        #expect(!CloudSavePrivateError.hostRecoveryRequired.permitsOfflineUse)
        #expect(!CloudSavePrivateError.missingTrustedManifest.permitsOfflineUse)
    }

    @Test func configuredZoneIntegrityFailureRetainsTheTerminalSessionReason() async throws {
        let (context, coordinator) = try await context()
        defer { withExtendedLifetime(coordinator) {} }
        #expect(throws: CloudSavePrivateError.missingTrustedManifest) {
            try context.validateTransportError(CKError(.zoneNotFound))
        }
        let fetches = CloudSaveFetchCoordinator()
        let request = try await fetches.prepareRequest()
        await fetches.beginFetch()
        await fetches.failConfiguredZoneFetch(error: CKError(.permissionFailure))
        await fetches.completeFetch()
        do { try await fetches.validate(request, preservingTransportError: true) } catch {
            #expect(
                CloudSavePrivateError.normalize(error) as? CloudSavePrivateError
                    == .transport(.restricted, retryAfterSeconds: nil))
        }
    }

    @Test func accountReverificationDrainsOldCheckpointWritesBeforeReturningToTheSameStore() async throws {
        let server = CloudSavePrivateTransportMock()
        let changes = AsyncStream<Void>.makeStream()
        let drains = AsyncStream<Void>.makeStream()
        let coordinator = CloudSavePrivateCoordinator(
            transport: server, changes: changes.stream, onCallbackDrainWait: { drains.continuation.yield(()) })
        let account = try await CloudSaveManifestFixture.account(coordinator)
        let bootstrap = try await CloudSaveManifestFixture.bootstrap(coordinator, account: account, proposed: 7)
        let oldContext = try await coordinator.sessionContext(for: bootstrap)
        let durable = CheckpointStore()
        let write = CloudSaveTestSuspension()
        let oldWrite = Task {
            try await oldContext.withClientCallback { await durable.persist(1, after: write) }
        }
        await write.waitUntilSuspended()
        var events = coordinator.accountEvents.makeAsyncIterator()
        _ = await events.next()
        _ = await events.next()
        await server.setAccount("account-b")
        changes.continuation.yield(())
        #expect(await events.next() == .invalidated)
        var drainEvents = drains.stream.makeAsyncIterator()
        _ = await drainEvents.next()
        await server.setAccount("account-a")
        changes.continuation.yield(())
        #expect(await events.next() == .invalidated)
        #expect(await server.identityCount == 1)
        await write.resume()
        await #expect(throws: CloudSavePrivateError.sessionInvalidated) { try await oldWrite.value }
        guard case .resolved(.verified(let returning)) = await events.next() else {
            Issue.record("Only the returning account can publish after old callbacks drain.")
            return
        }
        #expect(returning.recordName == account.recordName)
        let nextBootstrap = try await CloudSaveManifestFixture.bootstrap(coordinator, account: returning, expected: 7)
        let next = try await coordinator.sessionContext(for: nextBootstrap)
        try await next.withClientCallback { await durable.persist(2) }
        #expect(await durable.writes == [1, 2])
        #expect(await durable.current == 2)
    }

    @Test func exactManifestReadRetiresItsEngineWhenIdentityDrifts() async throws {
        let (context, coordinator) = try await context()
        defer { withExtendedLifetime(coordinator) {} }
        let transport = CloudSavePrivateTransportMock()
        await transport.seed(record: CloudSaveManifestFixture.record(identity: 8))
        let engine = CloudSaveSessionEngineMock()
        let session = CloudSavePrivateSession(context: context, engine: engine, transport: transport)
        await #expect(throws: CloudSavePrivateError.manifestIdentityMismatch) {
            try await session.fetchRecord(CloudSaveManifestFixture.recordID)
        }
        #expect(await engine.retireCount == 1)
        await #expect(throws: CloudSavePrivateError.manifestIdentityMismatch) { try await session.sendNow() }
        #expect(await engine.sendCount == 0)
    }

    @Test func publicSessionFetchPreservesConfiguredZoneNetworkClassification() async throws {
        let (context, coordinator) = try await context()
        defer { withExtendedLifetime(coordinator) {} }
        let fetches = CloudSaveFetchCoordinator()
        let engine = CloudSaveSessionEngineMock(fetch: {
            let request = try await fetches.prepareRequest()
            await fetches.beginFetch()
            await fetches.failConfiguredZoneFetch(error: CKError(.networkUnavailable))
            await fetches.completeFetch()
            try await fetches.validate(request, preservingTransportError: true)
        })
        let session = CloudSavePrivateSession(
            context: context, engine: engine, transport: CloudSavePrivateTransportMock())
        await #expect(throws: CloudSavePrivateError.transport(.networkUnavailable, retryAfterSeconds: nil)) {
            try await session.fetchNow()
        }
        #expect(await engine.retireCount == 0)
    }

    @Test func recoveryReplacementWaitsForOldHostWritesEvenAfterEngineCancellationReturns() async throws {
        let (original, coordinator) = try await context()
        defer { withExtendedLifetime(coordinator) {} }
        let drains = AsyncStream<Void>.makeStream()
        let gate = CloudSaveAccessGate(onDrainWait: { drains.continuation.yield(()) })
        let context = CloudSavePrivateSessionContext(
            account: original.account, accountGate: original.accountGate, sessionGate: gate,
            zoneID: original.zoneID, manifestRecordID: original.manifestRecordID,
            validateManifest: original.validateManifest, onInvalidation: { _ in }
        )
        let durable = CheckpointStore()
        let paused = CloudSaveTestSuspension()
        let oldWrite = Task { try await context.withClientCallback { await durable.persist(1, after: paused) } }
        await paused.waitUntilSuspended()
        let engine = CloudSaveSessionEngineMock()
        let session = CloudSavePrivateSession(
            context: context, engine: engine, transport: CloudSavePrivateTransportMock())
        let replacement = Task {
            await session.invalidate()
            // Recovery reads and replaces the checkpoint only after retirement's host barrier.
            try await original.withClientCallback { await durable.persist(2) }
        }
        var events = drains.stream.makeAsyncIterator()
        _ = await events.next()
        #expect(await engine.retireCount == 1)
        #expect(await durable.writes.isEmpty)
        await paused.resume()
        await #expect(throws: CloudSavePrivateError.sessionInvalidated) { try await oldWrite.value }
        try await replacement.value
        #expect(await durable.current == 2)
        #expect(await durable.writes == [1, 2])
    }

    private var noteID: CKRecord.ID { CKRecord.ID(recordName: "note", zoneID: CloudSaveManifestFixture.zoneID) }

    /// Uses the coordinator's actual captured decoder and generation gate, not a test-only policy.
    private func context() async throws -> (CloudSavePrivateSessionContext, CloudSavePrivateCoordinator) {
        let coordinator = CloudSavePrivateCoordinator(transport: CloudSavePrivateTransportMock())
        let account = try await CloudSaveManifestFixture.account(coordinator)
        let bootstrap = try await CloudSaveManifestFixture.bootstrap(coordinator, account: account, proposed: 7)
        return (try await coordinator.sessionContext(for: bootstrap), coordinator)
    }
}

/// Models opaque checkpoint writes at the same callback lease boundary used by client.persist.
private actor CheckpointStore {
    private(set) var current = 0
    private(set) var writes: [Int] = []

    func persist(_ value: Int, after suspension: CloudSaveTestSuspension? = nil) async {
        await suspension?.suspend()
        current = value
        writes.append(value)
    }
}
