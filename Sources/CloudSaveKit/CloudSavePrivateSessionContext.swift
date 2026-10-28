import CloudKit
import Foundation

/// Immutable account and zone ownership shared by transport, engine, and host-callback guards.
final class CloudSavePrivateSessionContext: Sendable {
    let account: CloudSaveVerifiedAccount
    let accountGate: CloudSaveAccessGate
    let sessionGate: CloudSaveAccessGate
    let zoneID: CKRecordZone.ID
    let manifestRecordID: CKRecord.ID
    let validateManifest: @Sendable (CKRecord) throws -> Void
    let onInvalidation: @Sendable (CloudSavePrivateError) async -> Void

    /// Captures the exact verified generation and host topology for this session's lifetime.
    init(
        account: CloudSaveVerifiedAccount, accountGate: CloudSaveAccessGate,
        sessionGate: CloudSaveAccessGate = CloudSaveAccessGate(),
        zoneID: CKRecordZone.ID, manifestRecordID: CKRecord.ID,
        validateManifest: @escaping @Sendable (CKRecord) throws -> Void,
        onInvalidation: @escaping @Sendable (CloudSavePrivateError) async -> Void
    ) {
        self.account = account
        self.accountGate = accountGate
        self.sessionGate = sessionGate
        self.zoneID = zoneID
        self.manifestRecordID = manifestRecordID
        self.validateManifest = validateManifest
        self.onInvalidation = onInvalidation
    }

    /// Checks both account-wide revocation and this particular engine's terminal lifecycle.
    func check() throws {
        try accountGate.check()
        try sessionGate.check()
    }

    /// Tracks every admitted host callback across both session retirement and account generations.
    func withClientCallback<Value: Sendable>(
        _ operation: @Sendable () async throws -> Value
    ) async throws -> Value {
        try accountGate.beginCallback()
        defer { accountGate.endCallback() }
        try sessionGate.beginCallback()
        defer { sessionGate.endCallback() }
        let value = try await operation()
        try check()
        return value
    }

    /// Rejects manifest drift before applying any domain record in the same batch.
    func validateFetchedChanges(records: [CKRecord], deletedRecordIDs: [CKRecord.ID]) throws {
        try check()
        do {
            if deletedRecordIDs.contains(manifestRecordID) {
                throw CloudSavePrivateError.missingTrustedManifest
            }
            for record in records where record.recordID == manifestRecordID {
                try validateManifest(record)
            }
        } catch let reason as CloudSavePrivateError {
            sessionGate.close(reason)
            throw reason
        }
    }

    /// Only a matching sign-in may reconcile the original client's durable ledger.
    func validate(_ change: CloudSaveAccountChange) throws {
        try check()
        guard case .signedIn(let identity) = change, identity == account.recordName else {
            sessionGate.close()
            throw CloudSavePrivateError.sessionInvalidated
        }
    }

    /// Prevents the host ledger from altering its independently provisioned manifest.
    func validatePending(_ changes: [CloudSavePendingChange]) throws {
        try check()
        guard changes.allSatisfy({ $0.recordID.zoneID == zoneID && $0.recordID != manifestRecordID }) else {
            throw CloudSavePrivateError.wrongZone
        }
    }

    /// Extracts fatal account/zone failures before engine retry or destructive recovery callbacks.
    func validateTransportError(_ error: any Error) throws {
        if let reason = error as? CloudSavePrivateError {
            switch reason {
            case .accountTemporarilyUnavailable, .sessionInvalidated, .missingTrustedManifest,
                .manifestIdentityMismatch, .malformedManifest:
                throw reason
            default:
                break
            }
        }
        let cloudError = error as? CKError
        switch cloudError?.code {
        case .accountTemporarilyUnavailable: throw CloudSavePrivateError.accountTemporarilyUnavailable
        case .notAuthenticated: throw CloudSavePrivateError.sessionInvalidated
        case .zoneNotFound, .userDeletedZone: throw CloudSavePrivateError.missingTrustedManifest
        case .partialFailure:
            for nested in cloudError?.partialErrorsByItemID?.values ?? [:].values {
                try validateTransportError(nested)
            }
        default: break
        }
    }
}
