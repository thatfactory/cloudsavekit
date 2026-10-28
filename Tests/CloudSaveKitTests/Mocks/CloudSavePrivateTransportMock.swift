import CloudKit
import Foundation

@testable import CloudSaveKit

/// Simulates a private server's atomic conditional creates and suspended account/record responses.
actor CloudSavePrivateTransportMock: CloudSavePrivateTransport {
    var status: CKAccountStatus = .available
    var account = "account-a"
    var zoneExists = false
    var record: CKRecord?
    var fetchError: CKError?
    var createError: CKError?
    var identityError: CKError?
    var concurrentWinner: CKRecord?
    var losesCreateAcknowledgement = false
    var fetchSuspension: CloudSaveTestSuspension?
    var identitySuspension: CloudSaveTestSuspension?
    private(set) var fetchCount = 0
    private(set) var identityCount = 0
    private(set) var zoneSaveCount = 0
    private(set) var createCount = 0

    /// Configures server contents before a test starts requests.
    func seed(zoneExists: Bool = true, record: CKRecord? = nil) {
        self.zoneExists = zoneExists
        self.record = record
    }

    /// Changes system identity without exposing any real account or credentials.
    func setAccount(_ account: String, status: CKAccountStatus = .available) {
        self.account = account
        self.status = status
    }

    /// Injects a specific fetch failure; absence remains a separate server outcome.
    func failFetch(_ error: CKError?) { fetchError = error }

    /// Fails identity verification so a last-used account cannot become a verified offline token.
    func failIdentity(_ error: CKError?) { identityError = error }

    /// Injects an item-level creation conflict with a separately committed canonical winner.
    func conflictOnCreate(winner: CKRecord, error: CKError) {
        concurrentWinner = winner
        createError = error
    }

    /// Simulates a server commit whose acknowledgement never reaches the original caller.
    func loseNextCreateAcknowledgement() { losesCreateAcknowledgement = true }

    /// Holds reads after their result is captured to exercise stale-result rejection.
    func pauseFetch(_ suspension: CloudSaveTestSuspension) { fetchSuspension = suspension }

    /// Holds identity resolution after capturing the old identity.
    func pauseIdentity(_ suspension: CloudSaveTestSuspension) { identitySuspension = suspension }

    /// Returns the configured availability.
    func accountStatus() -> CKAccountStatus { status }

    /// Delivers even a cancelled late identity result, leaving the coordinator to reject it.
    func userRecordID() async throws -> CKRecord.ID {
        identityCount += 1
        let identity = CKRecord.ID(recordName: account)
        let failure = identityError
        await identitySuspension?.suspend()
        if let failure {
            throw failure
        }
        return identity
    }

    /// Returns only the exact record, with positive missing-zone and missing-record outcomes.
    func fetchRecord(_ recordID: CKRecord.ID) async throws -> CKRecord? {
        fetchCount += 1
        let result: Result<CKRecord?, any Error> = Result {
            if let fetchError {
                throw fetchError
            }
            guard zoneExists else {
                throw CKError(.zoneNotFound)
            }
            return record?.recordID == recordID ? record : nil
        }
        await fetchSuspension?.suspend()
        return try result.get()
    }

    /// Counts provisioning and preserves any existing zone contents.
    func ensureZone(_ zone: CKRecordZone) {
        zoneSaveCount += 1
        zoneExists = true
    }

    /// Commits atomically or reports the existing server winner as a conflict.
    func createIfAbsent(_ record: CKRecord) throws {
        createCount += 1
        if let concurrentWinner {
            self.record = concurrentWinner
        }
        if let createError {
            throw createError
        }
        guard self.record == nil else {
            throw CKError(.serverRecordChanged)
        }
        self.record = record
        if losesCreateAcknowledgement {
            losesCreateAcknowledgement = false
            throw CKError(.networkFailure)
        }
    }
}
