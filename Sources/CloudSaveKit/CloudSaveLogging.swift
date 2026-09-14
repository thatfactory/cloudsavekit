import AppLogger

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
}
