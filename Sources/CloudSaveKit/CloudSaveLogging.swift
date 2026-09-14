import AppLogger
import CloudKit

enum CloudSaveLogging {
    static let emoji = "☁️"
    static let subsystem = "com.thatfactory.cloudsavekit"

    static func log(
        level: AppLogLevel = .debug,
        _ message: String
    ) {
        let logger = AppLogger(
            subsystem: subsystem,
            category: "sync"
        )
        logger.log(
            level: level,
            formatted(message)
        )
    }

    /// Formats one package-owned message with the canonical privacy-safe prefix.
    static func formatted(_ message: String) -> String {
        "\(emoji) \(message)"
    }

    /// Describes the freshness barrier established for an explicit fetch request.
    static func fetchRequest(
        request: Int,
        requiredFetch: Int,
        waitedForPriorFetch: Bool
    ) -> String {
        "fetch request | request=\(request), required=\(requiredFetch), waited=\(waitedForPriorFetch)"
    }

    /// Describes one terminal explicit request outcome.
    static func fetchRequestSucceeded(request: Int) -> String {
        "fetch request | request=\(request), result=success"
    }

    /// Describes a CKSyncEngine fetch-generation transition.
    static func fetchGeneration(_ generation: Int, phase: String) -> String {
        "fetch generation | generation=\(generation), phase=\(phase)"
    }

    /// Describes configured-zone server-change knowledge without exposing its identity.
    static func fetchState(phase: String, configuredZoneDirty: Bool) -> String {
        "fetch state | phase=\(phase), configured-zone-dirty=\(configuredZoneDirty)"
    }

    /// Describes bounded database-change discovery without exposing zone identities.
    static func fetchedDatabaseChanges(
        modifications: Int,
        deletions: Int,
        configuredZoneChanged: Bool
    ) -> String {
        "fetch database | modifications=\(modifications), deletions=\(deletions), configured-zone-changed=\(configuredZoneChanged)"
    }

    /// Describes bounded configured-zone record changes without exposing record identities.
    static func fetchedConfiguredZoneChanges(modifications: Int, deletions: Int) -> String {
        "fetch zone | phase=changes, modifications=\(modifications), deletions=\(deletions)"
    }

    /// Describes configured-zone fetch completion with a privacy-safe failure classification.
    static func configuredZoneFetchCompleted(error: CKError?) -> String {
        guard let error else {
            return "fetch zone | phase=completed, result=success"
        }
        return
            "fetch zone | phase=completed, result=failure, classification=\(failureToken(CloudSaveFailure(error: error))), code=\(error.errorCode)"
    }

    /// Converts a stable failure category to a log-safe token.
    private static func failureToken(_ failure: CloudSaveFailure) -> String {
        switch failure {
        case .accountUnavailable: "account-unavailable"
        case .configuration: "configuration"
        case .localPersistence: "local-persistence"
        case .networkUnavailable: "network-unavailable"
        case .quotaExceeded: "quota-exceeded"
        case .recordConflict: "record-conflict"
        case .restricted: "restricted"
        case .zoneUnavailable: "zone-unavailable"
        case .unknown: "unknown"
        }
    }
}
