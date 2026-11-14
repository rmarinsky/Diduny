import Foundation
import OSLog

enum AppLogger {
    /// OSLog subsystem for the engine loggers. Set it before the first log call; the loggers
    /// below are created lazily on first use.
    static var subsystem = Constants.bundleIdentifier

    static let layout = Logger(subsystem: subsystem, category: "Layout")
    static let analytics = Logger(subsystem: subsystem, category: "Analytics")

    static func pre(_ logger: Logger, _ message: String) {
        logger.debug("\(message, privacy: .private)")
    }

    static func action(_ logger: Logger, _ message: String) {
        logger.notice("\(message, privacy: .private)")
    }

    static func post(_ logger: Logger, _ message: String) {
        logger.debug("\(message, privacy: .private)")
    }

    static func warn(_ logger: Logger, _ message: String) {
        logger.warning("\(message, privacy: .private)")
    }

    static func error(_ logger: Logger, _ message: String) {
        logger.error("\(message, privacy: .private)")
    }
}
