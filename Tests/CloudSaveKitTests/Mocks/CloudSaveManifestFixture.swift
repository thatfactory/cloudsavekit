import CloudKit
import Foundation

@testable import CloudSaveKit

/// Uses a neutral integer identity, alternate zone, and non-vocabulary schema to demonstrate reuse.
enum CloudSaveManifestFixture {
    static let zoneID = CKRecordZone.ID(zoneName: "NotebookPrivate")
    static let recordID = CKRecord.ID(recordName: "settings", zoneID: zoneID)

    /// Creates a neutral manifest without any WortJagd identifiers or schema fields.
    static func record(identity: Int) -> CKRecord {
        let record = CKRecord(recordType: "NotebookManifest", recordID: recordID)
        record["revision"] = NSNumber(value: identity)
        return record
    }

    /// Performs the host's pure schema decoding.
    static func decode(_ record: CKRecord) throws -> Int {
        guard let revision = record["revision"] as? NSNumber else {
            throw CocoaError(.coderInvalidValue)
        }
        return revision.intValue
    }

    /// Obtains a genuine coordinator-issued token for tests.
    static func account(_ coordinator: CloudSavePrivateCoordinator) async throws -> CloudSaveVerifiedAccount {
        guard case .verified(let account) = try await coordinator.refreshAccount() else {
            throw CloudSavePrivateError.sessionInvalidated
        }
        return account
    }

    /// Exercises the public generic API with one neutral host schema.
    static func bootstrap(
        _ coordinator: CloudSavePrivateCoordinator,
        account: CloudSaveVerifiedAccount,
        expected: Int? = nil,
        proposed: Int = 1
    ) async throws -> CloudSavePrivateBootstrap<Int> {
        try await coordinator.bootstrapManifest(
            for: account, zoneName: zoneID.zoneName, recordType: "NotebookManifest", recordName: recordID.recordName,
            expectedIdentity: expected, makeInitialRecord: { _ in record(identity: proposed) }, decodeIdentity: decode
        )
    }
}
