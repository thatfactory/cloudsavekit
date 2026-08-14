import CloudKit
import Foundation

/// A stable, privacy-safe failure category suitable for application state.
public enum CloudSaveFailure: Equatable, Sendable {
    /// No usable iCloud account is currently available.
    case accountUnavailable

    /// CloudKit rejected the configured container or database.
    case configuration

    /// Local save data or CKSyncEngine state couldn't be persisted.
    case localPersistence

    /// A network connection is currently unavailable.
    case networkUnavailable

    /// The person's iCloud storage quota is exhausted.
    case quotaExceeded

    /// A record requires application or user conflict resolution.
    case recordConflict

    /// CloudKit rejected the operation because of permissions or restrictions.
    case restricted

    /// The custom record zone needs to be recreated.
    case zoneUnavailable

    /// An unclassified CloudKit failure, retaining only its numeric code.
    case unknown(code: Int)
}

extension CloudSaveFailure {
    init(error: any Error) {
        guard let cloudError = error as? CKError else {
            self = .unknown(code: (error as NSError).code)
            return
        }

        switch cloudError.code {
        case .accountTemporarilyUnavailable, .notAuthenticated:
            self = .accountUnavailable
        case .badContainer, .badDatabase, .invalidArguments:
            self = .configuration
        case .networkFailure, .networkUnavailable, .requestRateLimited, .serviceUnavailable, .zoneBusy:
            self = .networkUnavailable
        case .quotaExceeded:
            self = .quotaExceeded
        case .serverRecordChanged:
            self = .recordConflict
        case .managedAccountRestricted, .missingEntitlement, .permissionFailure:
            self = .restricted
        case .zoneNotFound:
            self = .zoneUnavailable
        default:
            self = .unknown(code: cloudError.errorCode)
        }
    }
}
