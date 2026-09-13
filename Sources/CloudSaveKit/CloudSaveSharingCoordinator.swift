import CloudKit

/// Creates, accepts, and discovers zone-wide CloudKit shares without owning presentation UI.
public actor CloudSaveSharingCoordinator {
    private let container: CKContainer

    /// Creates a coordinator for one CloudKit container.
    public init(container: CKContainer) {
        self.container = container
    }

    /// Returns the existing private zone-wide share, or creates it when absent.
    public func ensureZoneWideShare(for zoneID: CKRecordZone.ID) async throws -> CKShare {
        let database = container.privateCloudDatabase
        let recordID = CKRecord.ID(
            recordName: CKRecordNameZoneWideShare,
            zoneID: zoneID
        )

        do {
            guard let share = try await database.record(for: recordID) as? CKShare else {
                throw CloudSaveSharingError.unsupportedShare
            }
            return share
        } catch let error as CKError where error.code == .unknownItem {
            let share = CKShare(recordZoneID: zoneID)
            share.publicPermission = .none
            do {
                guard let savedShare = try await database.save(share) as? CKShare else {
                    throw CloudSaveSharingError.unsupportedShare
                }
                return savedShare
            } catch let saveError as CKError where saveError.code == .serverRecordChanged {
                guard let existingShare = try await database.record(for: recordID) as? CKShare else {
                    throw CloudSaveSharingError.unsupportedShare
                }
                return existingShare
            }
        }
    }

    /// Accepts a zone-wide invitation and returns its exact shared-zone identifier.
    public func accept(metadata: CKShare.Metadata) async throws -> CKRecordZone.ID {
        guard metadata.containerIdentifier == container.containerIdentifier else {
            throw CloudSaveSharingError.unexpectedContainer
        }
        guard metadata.share.recordID.recordName == CKRecordNameZoneWideShare else {
            throw CloudSaveSharingError.unsupportedShare
        }

        switch metadata.participantStatus {
        case .accepted:
            return metadata.share.recordID.zoneID
        case .pending:
            let share = try await container.accept(metadata)
            return share.recordID.zoneID
        case .removed, .unknown:
            throw CloudSaveSharingError.unsupportedShare
        @unknown default:
            throw CloudSaveSharingError.unsupportedShare
        }
    }

    /// Lists every record zone currently shared with the current account.
    public func sharedRecordZones() async throws -> [CKRecordZone] {
        try await container.sharedCloudDatabase.allRecordZones()
    }
}
