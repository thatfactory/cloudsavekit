import CloudKit
import Foundation
import Synchronization
import Testing

@testable import CloudSaveKit

/// Tests immutable client binding, late completion fencing, suspension, and guarded recovery policy.
struct CloudSavePrivateSessionTests {
    @Test func accountInvalidationIsPublishedBeforeAwaitingEngineCancellation() async throws {
        let signal = AsyncStream<CloudSavePrivateError>.makeStream()
        let context = CloudSavePrivateSessionContext(
            account: CloudSaveVerifiedAccount(recordName: "account-a", coordinatorID: UUID(), generation: UUID()),
            accountGate: CloudSaveAccessGate(), zoneID: CloudSaveManifestFixture.zoneID,
            manifestRecordID: CloudSaveManifestFixture.recordID, validateManifest: { _ in },
            onInvalidation: { signal.continuation.yield($0) }
        )
        let engine = CloudSaveSessionEngineMock()
        let retirement = CloudSaveTestSuspension()
        await engine.pauseRetirement(retirement)
        await engine.failSend(CKError(.notAuthenticated))
        let session = CloudSavePrivateSession(
            context: context, engine: engine, transport: CloudSavePrivateTransportMock())
        let request = Task { try await session.sendNow() }
        var events = signal.stream.makeAsyncIterator()
        #expect(await events.next() == .sessionInvalidated)
        await retirement.waitUntilSuspended()
        #expect(throws: CloudSavePrivateError.sessionInvalidated) { try context.check() }
        await retirement.resume()
        await #expect(throws: CloudSavePrivateError.sessionInvalidated) { try await request.value }
    }

    @Test func invalidationRejectsLateAssetWithoutPublishingOrStartingMoreRequests() async throws {
        let server = CloudSavePrivateTransportMock()
        await server.seed(record: CloudSaveManifestFixture.record(identity: 7))
        let suspension = CloudSaveTestSuspension()
        await server.pauseFetch(suspension)
        let context = Self.context()
        let engine = CloudSaveSessionEngineMock()
        let session = CloudSavePrivateSession(context: context, engine: engine, transport: server)
        let operation = Task { try await session.fetchRecord(CloudSaveManifestFixture.recordID) }
        await suspension.waitUntilSuspended()
        await session.invalidate()
        await suspension.resume()
        await #expect(throws: CloudSavePrivateError.sessionInvalidated) { try await operation.value }
        await #expect(throws: CloudSavePrivateError.sessionInvalidated) {
            try await session.fetchRecord(CloudSaveManifestFixture.recordID)
        }
        #expect(await server.fetchCount == 1)
        #expect(await engine.retireCount == 1)
    }

    @Test func wrongZoneFailsBeforeTransport() async throws {
        let server = CloudSavePrivateTransportMock()
        let session = CloudSavePrivateSession(
            context: Self.context(), engine: CloudSaveSessionEngineMock(), transport: server)
        await #expect(throws: CloudSavePrivateError.wrongZone) {
            try await session.fetchRecord(CKRecord.ID(recordName: "asset", zoneID: CKRecordZone.ID(zoneName: "Other")))
        }
        #expect(await server.fetchCount == 0)
    }

    @Test func temporaryFailureRetiresSessionAndPreservesLocalCommitForFreshSession() async throws {
        let client = CloudSavePrivateClientMock()
        let server = CloudSavePrivateTransportMock()
        let firstContext = Self.context()
        let firstEngine = CloudSaveSessionEngineMock(
            client: CloudSavePrivateClient(client: client, context: firstContext))
        let first = CloudSavePrivateSession(context: firstContext, engine: firstEngine, transport: server)
        await firstEngine.failSend(CKError(.accountTemporarilyUnavailable))
        await #expect(throws: CloudSavePrivateError.accountTemporarilyUnavailable) { try await first.sendNow() }
        let pending = CloudSavePendingChange.save(Self.recordID)
        await client.commit(pending)
        await #expect(throws: CloudSavePrivateError.accountTemporarilyUnavailable) {
            try await first.enqueue([pending])
        }
        await #expect(throws: CloudSavePrivateError.accountTemporarilyUnavailable) { try await first.sendNow() }
        #expect(await firstEngine.sendCount == 1)
        #expect(await firstEngine.enqueued.isEmpty)
        let nextContext = Self.context()
        let nextEngine = CloudSaveSessionEngineMock(
            client: CloudSavePrivateClient(client: client, context: nextContext))
        let next = CloudSavePrivateSession(context: nextContext, engine: nextEngine, transport: server)
        try await next.start()
        #expect(await nextEngine.restored == [pending])
        #expect(await client.pendingChanges() == [pending])
    }

    @Test func staleLedgerAndMaterializationCannotCrossAccountBoundary() async throws {
        let client = CloudSavePrivateClientMock()
        let suspension = CloudSaveTestSuspension()
        await client.commit(.save(Self.recordID))
        await client.pauseReads(suspension)
        let context = Self.context()
        let guarded = CloudSavePrivateClient(client: client, context: context)
        let ledger = Task { try await guarded.pendingChanges() }
        let record = Task { try await guarded.record(for: Self.recordID) }
        await suspension.waitUntilSuspended(count: 2)
        context.accountGate.close()
        await suspension.resume()
        await #expect(throws: CloudSavePrivateError.sessionInvalidated) { try await ledger.value }
        await #expect(throws: CloudSavePrivateError.sessionInvalidated) { try await record.value }
        #expect(await client.pendingChanges() == [.save(Self.recordID)])
    }

    @Test func fixedAccountNeverCallsMutableHostRebindingOrClearsMissingZone() async throws {
        let client = CloudSavePrivateClientMock()
        let context = Self.context()
        let guarded = CloudSavePrivateClient(client: client, context: context)
        try guarded.handle(accountChange: .signedIn(currentAccountID: "account-a"))
        #expect(throws: CloudSavePrivateError.sessionInvalidated) {
            try guarded.handle(accountChange: .signedIn(currentAccountID: "account-b"))
        }
        await #expect(throws: CloudSavePrivateError.missingTrustedManifest) {
            try await guarded.applyDeletedZones([CloudSaveManifestFixture.zoneID])
        }
        #expect(await client.accountCallbackCount == 0)
        #expect(await client.deletedZoneCallbackCount == 0)
    }

    @Test func accountAToBToARestoresOnlyEachOriginalLedger() async throws {
        let firstClient = CloudSavePrivateClientMock()
        let secondClient = CloudSavePrivateClientMock()
        await firstClient.commit(.save(Self.recordID))
        await secondClient.commit(.delete(Self.recordID))
        let firstContext = Self.context()
        let first = CloudSavePrivateClient(client: firstClient, context: firstContext)
        #expect(try await first.pendingChanges() == [.save(Self.recordID)])
        firstContext.accountGate.close()
        let secondContext = Self.context(account: "account-b")
        let second = CloudSavePrivateClient(client: secondClient, context: secondContext)
        #expect(try await second.pendingChanges() == [.delete(Self.recordID)])
        secondContext.accountGate.close()
        let returning = CloudSavePrivateClient(client: firstClient, context: Self.context())
        #expect(try await returning.pendingChanges() == [.save(Self.recordID)])
        await #expect(throws: CloudSavePrivateError.sessionInvalidated) { try await first.pendingChanges() }
        await #expect(throws: CloudSavePrivateError.sessionInvalidated) { try await second.pendingChanges() }
    }

    @Test(arguments: [CKError.Code.zoneNotFound, .userDeletedZone, .accountTemporarilyUnavailable, .notAuthenticated])
    func automaticEventPolicyRetainsFatalFailuresInsidePartialErrors(code: CKError.Code) {
        let expected: CloudSavePrivateError =
            switch code {
            case .zoneNotFound, .userDeletedZone: .missingTrustedManifest
            case .accountTemporarilyUnavailable: .accountTemporarilyUnavailable
            default: .sessionInvalidated
            }
        let error = CKError(.partialFailure, userInfo: [CKPartialErrorsByItemIDKey: [Self.recordID: CKError(code)]])
        #expect(throws: expected) { try Self.context().validateTransportError(error) }
    }

    @Test func manifestCannotEnterLocalMutationLedger() async throws {
        let client = CloudSavePrivateClientMock()
        await client.commit(.delete(CloudSaveManifestFixture.recordID))
        let guarded = CloudSavePrivateClient(client: client, context: Self.context())
        await #expect(throws: CloudSavePrivateError.wrongZone) { try await guarded.pendingChanges() }
    }

    @Test func throttlePersistsAcrossCallsAndRechecksInvalidationAfterWaiting() async throws {
        let instant = ContinuousClock.now
        let delays = Mutex<[Duration]>([])
        let access = CloudSaveAccessGate()
        let gate = CloudSavePrivateRequestGate(
            now: { instant },
            sleep: { duration in
                delays.withLock { $0.append(duration) }
                access.close()
            }
        )
        let rateLimit = CKError(.requestRateLimited, userInfo: [CKErrorRetryAfterKey: 12.0])
        await #expect(throws: CKError.self) {
            try await gate.perform(validate: { try access.check() }, operation: { throw rateLimit })
        }
        await #expect(throws: CloudSavePrivateError.sessionInvalidated) {
            try await gate.perform(
                validate: { try access.check() }, operation: { Issue.record("Stale request reached transport") })
        }
        #expect(delays.withLock { $0 } == [.seconds(12)])
    }

    @Test func perItemFailurePrecedesAggregateAndAggregateFailureCannotBecomeSuccess() throws {
        let result = CloudSaveOperationResult<Int>()
        result.set(.failure(CKError(.permissionFailure)))
        #expect(throws: CKError(.permissionFailure)) { try result.finish(.failure(CKError(.partialFailure))) }
        result.set(.success(7))
        #expect(throws: CKError(.networkFailure)) { try result.finish(.failure(CKError(.networkFailure))) }
    }

    private static let recordID = CKRecord.ID(recordName: "note-1", zoneID: CloudSaveManifestFixture.zoneID)

    /// Creates a package-internal token only for focused policy tests; public callers cannot forge it.
    private static func context(account: String = "account-a") -> CloudSavePrivateSessionContext {
        CloudSavePrivateSessionContext(
            account: CloudSaveVerifiedAccount(recordName: account, coordinatorID: UUID(), generation: UUID()),
            accountGate: CloudSaveAccessGate(), zoneID: CloudSaveManifestFixture.zoneID,
            manifestRecordID: CloudSaveManifestFixture.recordID, validateManifest: { _ in }, onInvalidation: { _ in }
        )
    }
}
