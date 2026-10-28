import CloudKit
import Foundation

/// Performs exact private-database operations and cancels them with the requesting task.
struct CloudSaveCloudKitTransport: CloudSavePrivateTransport {
    let container: CKContainer
    let database: CKDatabase

    /// Constructs service objects inside the package boundary.
    init(containerIdentifier: String) {
        container = CKContainer(identifier: containerIdentifier)
        database = container.privateCloudDatabase
    }

    /// Resolves availability without interpreting an unavailable account as absence of cloud data.
    func accountStatus() async throws -> CKAccountStatus { try await container.accountStatus() }

    /// Resolves the opaque identity in the active system context.
    func userRecordID() async throws -> CKRecord.ID { try await container.userRecordID() }

    /// Returns nil only for a positively classified missing record, retaining missing-zone failures.
    func fetchRecord(_ recordID: CKRecord.ID) async throws -> CKRecord? {
        let operation = CKFetchRecordsOperation(recordIDs: [recordID])
        let result = CloudSaveOperationResult<CKRecord>()
        operation.perRecordResultBlock = { _, value in result.set(value) }
        do {
            return try await withTaskCancellationHandler {
                try Task.checkCancellation()
                return try await withCheckedThrowingContinuation { continuation in
                    operation.fetchRecordsResultBlock = { value in
                        continuation.resume(with: Result { try result.finish(value) })
                    }
                    database.add(operation)
                }
            } onCancel: {
                operation.cancel()
            }
        } catch {
            let itemError = CloudSavePrivateError.itemError(error, for: recordID)
            if (itemError as? CKError)?.code == .unknownItem {
                return nil
            }
            throw itemError
        }
    }

    /// Provisions exactly the requested zone after verified first-use absence.
    func ensureZone(_ zone: CKRecordZone) async throws {
        let operation = CKModifyRecordZonesOperation(recordZonesToSave: [zone])
        let result = CloudSaveOperationResult<CKRecordZone>()
        operation.perRecordZoneSaveBlock = { _, value in result.set(value) }
        let _: CKRecordZone = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                operation.modifyRecordZonesResultBlock = { value in
                    continuation.resume(with: Result { try result.finish(value) })
                }
                database.add(operation)
            }
        } onCancel: {
            operation.cancel()
        }
    }

    /// Uses a checked create policy; callers reread the server winner after success or conflict.
    func createIfAbsent(_ record: CKRecord) async throws {
        let operation = CKModifyRecordsOperation(recordsToSave: [record])
        operation.savePolicy = .ifServerRecordUnchanged
        operation.isAtomic = true
        let result = CloudSaveOperationResult<CKRecord>()
        operation.perRecordSaveBlock = { _, value in result.set(value) }
        let _: CKRecord = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                operation.modifyRecordsResultBlock = { value in
                    continuation.resume(with: Result { try result.finish(value) })
                }
                database.add(operation)
            }
        } onCancel: {
            operation.cancel()
        }
    }
}
