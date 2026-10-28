import CloudKit
import Foundation
import Testing

@testable import CloudSaveKit

/// Verifies conditional provisioning and verified-account provenance with no CloudKit credentials.
struct CloudSavePrivateCoordinatorTests {
    @Test func repeatedAccountNotificationsSupersedeSuspendedIdentityResolution() async throws {
        let server = CloudSavePrivateTransportMock()
        let notifications = AsyncStream<Void>.makeStream()
        let coordinator = CloudSavePrivateCoordinator(transport: server, changes: notifications.stream)
        let suspension = CloudSaveTestSuspension()
        await server.pauseIdentity(suspension)
        let original = Task { try await coordinator.refreshAccount() }
        await suspension.waitUntilSuspended()
        var updates = coordinator.accountEvents.makeAsyncIterator()
        #expect(await updates.next() == .invalidated)
        await server.setAccount("account-b")
        notifications.continuation.yield(())
        #expect(await updates.next() == .invalidated)
        await suspension.waitUntilSuspended(count: 2)
        await server.setAccount("account-a")
        notifications.continuation.yield(())
        #expect(await updates.next() == .invalidated)
        await suspension.waitUntilSuspended(count: 3)
        await suspension.resume()
        await #expect(throws: CloudSavePrivateError.sessionInvalidated) { try await original.value }
        guard case .resolved(.verified(let current)) = await updates.next() else {
            Issue.record("Only the final account generation may publish verification.")
            return
        }
        #expect(current.recordName == "account-a")
        #expect(try await CloudSaveManifestFixture.bootstrap(coordinator, account: current).value == 1)
    }

    @Test func failedColdIdentityResolutionNeverExposesAUsableAccount() async throws {
        let server = CloudSavePrivateTransportMock()
        await server.failIdentity(CKError(.networkUnavailable))
        let coordinator = CloudSavePrivateCoordinator(transport: server)
        await #expect(throws: CloudSavePrivateError.transport(.networkUnavailable, retryAfterSeconds: nil)) {
            try await coordinator.refreshAccount()
        }
        var updates = coordinator.accountEvents.makeAsyncIterator()
        #expect(await updates.next() == .invalidated)
        #expect(await updates.next() == .resolved(.indeterminate))
        #expect(await server.fetchCount == 0)
    }

    @Test func nestedPerRecordConflictRereadsCanonicalWinner() async throws {
        let server = CloudSavePrivateTransportMock()
        await server.seed()
        let conflict = CKError(
            .partialFailure,
            userInfo: [CKPartialErrorsByItemIDKey: [CloudSaveManifestFixture.recordID: CKError(.serverRecordChanged)]]
        )
        await server.conflictOnCreate(winner: CloudSaveManifestFixture.record(identity: 42), error: conflict)
        let coordinator = CloudSavePrivateCoordinator(transport: server)
        let account = try await CloudSaveManifestFixture.account(coordinator)
        #expect(try await CloudSaveManifestFixture.bootstrap(coordinator, account: account).value == 42)
        #expect(await server.createCount == 1)
    }

    @Test func firstAndRepeatedProvisioningReadCanonicalServerIdentity() async throws {
        let server = CloudSavePrivateTransportMock()
        let coordinator = CloudSavePrivateCoordinator(transport: server)
        let account = try await CloudSaveManifestFixture.account(coordinator)
        let first = try await CloudSaveManifestFixture.bootstrap(coordinator, account: account, proposed: 7)
        let next = try await CloudSaveManifestFixture.bootstrap(coordinator, account: account, expected: 7, proposed: 8)
        #expect(first.value == 7)
        #expect(next.value == 7)
        #expect(await server.zoneSaveCount == 1)
        #expect(await server.createCount == 1)
    }

    @Test func concurrentClientsAlwaysBindTheConditionalCreateWinner() async throws {
        let server = CloudSavePrivateTransportMock()
        await server.seed()
        let suspension = CloudSaveTestSuspension()
        await server.pauseFetch(suspension)
        let phone = CloudSavePrivateCoordinator(transport: server)
        let television = CloudSavePrivateCoordinator(transport: server)
        let phoneAccount = try await CloudSaveManifestFixture.account(phone)
        let televisionAccount = try await CloudSaveManifestFixture.account(television)
        let first = Task { try await CloudSaveManifestFixture.bootstrap(phone, account: phoneAccount, proposed: 7) }
        let second = Task {
            try await CloudSaveManifestFixture.bootstrap(television, account: televisionAccount, proposed: 8)
        }
        await suspension.waitUntilSuspended(count: 2)
        await suspension.resume()
        let results = try await (first.value, second.value)
        #expect(results.0.value == results.1.value)
        #expect([7, 8].contains(results.0.value))
        #expect(await server.createCount == 2)
        #expect(await server.zoneSaveCount == 0)
    }

    @Test func interruptedZoneOnlyProvisioningFinishesWithoutReplacingAnything() async throws {
        let server = CloudSavePrivateTransportMock()
        await server.seed()
        let coordinator = CloudSavePrivateCoordinator(transport: server)
        let account = try await CloudSaveManifestFixture.account(coordinator)
        #expect(try await CloudSaveManifestFixture.bootstrap(coordinator, account: account).value == 1)
        #expect(await server.zoneSaveCount == 0)
        #expect(await server.createCount == 1)
    }

    @Test func lostCreateAcknowledgementIsRediscoveredWithoutSecondCreate() async throws {
        let server = CloudSavePrivateTransportMock()
        await server.loseNextCreateAcknowledgement()
        let coordinator = CloudSavePrivateCoordinator(transport: server)
        let account = try await CloudSaveManifestFixture.account(coordinator)
        await #expect(throws: CloudSavePrivateError.transport(.networkUnavailable, retryAfterSeconds: nil)) {
            try await CloudSaveManifestFixture.bootstrap(coordinator, account: account, proposed: 7)
        }
        #expect(try await CloudSaveManifestFixture.bootstrap(coordinator, account: account, proposed: 8).value == 7)
        #expect(await server.createCount == 1)
    }

    @Test(arguments: [false, true])
    func knownMissingManifestNeverCreatesAReplacement(zoneExists: Bool) async throws {
        let server = CloudSavePrivateTransportMock()
        await server.seed(zoneExists: zoneExists)
        let coordinator = CloudSavePrivateCoordinator(transport: server)
        let account = try await CloudSaveManifestFixture.account(coordinator)
        await #expect(throws: CloudSavePrivateError.missingTrustedManifest) {
            try await CloudSaveManifestFixture.bootstrap(coordinator, account: account, expected: 7)
        }
        #expect(await server.createCount == 0)
        #expect(await server.zoneSaveCount == 0)
    }

    @Test func networkFailureNeverMasqueradesAsAbsence() async throws {
        let server = CloudSavePrivateTransportMock()
        await server.failFetch(CKError(.networkFailure))
        let coordinator = CloudSavePrivateCoordinator(transport: server)
        let account = try await CloudSaveManifestFixture.account(coordinator)
        await #expect(throws: CloudSavePrivateError.transport(.networkUnavailable, retryAfterSeconds: nil)) {
            try await CloudSaveManifestFixture.bootstrap(coordinator, account: account)
        }
        #expect(await server.createCount == 0)
        #expect(await server.zoneSaveCount == 0)
    }

    @Test func malformedAndContradictoryManifestFailClosed() async throws {
        let server = CloudSavePrivateTransportMock()
        let coordinator = CloudSavePrivateCoordinator(transport: server)
        let account = try await CloudSaveManifestFixture.account(coordinator)
        await server.seed(record: CloudSaveManifestFixture.record(identity: 8))
        await #expect(throws: CloudSavePrivateError.manifestIdentityMismatch) {
            try await CloudSaveManifestFixture.bootstrap(coordinator, account: account, expected: 7)
        }
        await server.seed(record: CKRecord(recordType: "NotebookManifest", recordID: CloudSaveManifestFixture.recordID))
        await #expect(throws: CloudSavePrivateError.malformedManifest) {
            try await CloudSaveManifestFixture.bootstrap(coordinator, account: account)
        }
        #expect(await server.createCount == 0)
    }

    @Test func staleOrForeignVerifiedTokensCannotProvision() async throws {
        let server = CloudSavePrivateTransportMock()
        let first = CloudSavePrivateCoordinator(transport: server)
        let second = CloudSavePrivateCoordinator(transport: server)
        let oldAccount = try await CloudSaveManifestFixture.account(first)
        _ = try await CloudSaveManifestFixture.account(second)
        await #expect(throws: CloudSavePrivateError.sessionInvalidated) {
            try await CloudSaveManifestFixture.bootstrap(second, account: oldAccount)
        }
        await server.setAccount("account-b")
        _ = try await CloudSaveManifestFixture.account(first)
        await #expect(throws: CloudSavePrivateError.sessionInvalidated) {
            try await CloudSaveManifestFixture.bootstrap(first, account: oldAccount)
        }
        #expect(await server.fetchCount == 0)
    }

    @Test(arguments: [CKAccountStatus.noAccount, .restricted, .temporarilyUnavailable, .couldNotDetermine])
    func unverifiedAvailabilityNeverReadsIdentityOrRecords(status: CKAccountStatus) async throws {
        let server = CloudSavePrivateTransportMock()
        await server.setAccount("unverified", status: status)
        let coordinator = CloudSavePrivateCoordinator(transport: server)
        _ = try await coordinator.refreshAccount()
        #expect(await server.identityCount == 0)
        #expect(await server.fetchCount == 0)
    }

    @Test func accountNotificationFencesSuspendedBootstrapBeforeResolvingNewIdentity() async throws {
        let server = CloudSavePrivateTransportMock()
        let events = AsyncStream<Void>.makeStream()
        let coordinator = CloudSavePrivateCoordinator(transport: server, changes: events.stream)
        let account = try await CloudSaveManifestFixture.account(coordinator)
        var updates = coordinator.accountEvents.makeAsyncIterator()
        #expect(await updates.next() == .invalidated)
        #expect(await updates.next() == .resolved(.verified(account)))
        let suspension = CloudSaveTestSuspension()
        await server.pauseFetch(suspension)
        let operation = Task { try await CloudSaveManifestFixture.bootstrap(coordinator, account: account) }
        await suspension.waitUntilSuspended()
        await server.setAccount("account-b")
        events.continuation.yield(())
        #expect(await updates.next() == .invalidated)
        await suspension.resume()
        await #expect(throws: CloudSavePrivateError.sessionInvalidated) { try await operation.value }
        #expect(await server.zoneSaveCount == 0)
        #expect(await server.createCount == 0)
    }
}
