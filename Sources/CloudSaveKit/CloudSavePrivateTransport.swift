import CloudKit

/// Internal CloudKit seam for deterministic account and conditional-provisioning tests.
protocol CloudSavePrivateTransport: Sendable {
    func accountStatus() async throws -> CKAccountStatus
    func userRecordID() async throws -> CKRecord.ID
    func fetchRecord(_ recordID: CKRecord.ID) async throws -> CKRecord?
    func ensureZone(_ zone: CKRecordZone) async throws
    func createIfAbsent(_ record: CKRecord) async throws
}
