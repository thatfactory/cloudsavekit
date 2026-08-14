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
            "\(emoji) \(message)"
        )
    }
}
