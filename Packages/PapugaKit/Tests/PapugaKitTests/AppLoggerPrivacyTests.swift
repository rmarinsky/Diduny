import OSLog
import XCTest
@testable import PapugaKit

final class AppLoggerPrivacyTests: XCTestCase {
    func test_actionRedactsDynamicMessageFromUnifiedLog() throws {
        let category = "PrivacyTest-\(UUID().uuidString)"
        let logger = Logger(subsystem: Constants.bundleIdentifier, category: category)
        let sentinel = "papuga-private-sentinel"

        AppLogger.action(logger, "Private value: \(sentinel)")

        let entries = try waitForLogEntries(category: category) { !$0.isEmpty }
        XCTAssertEqual(entries.last?.formatString, "%{private}s")
    }

    private func waitForLogEntries(
        category: String,
        until condition: ([LogEntry]) -> Bool
    ) throws -> [LogEntry] {
        let deadline = Date().addingTimeInterval(5)
        var entries: [LogEntry] = []
        repeat {
            entries = try logEntries(category: category)
            if condition(entries) { return entries }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline
        return entries
    }

    private func logEntries(category: String) throws -> [LogEntry] {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        process.arguments = [
            "show", "--last", "1m", "--style", "json",
            "--predicate", "subsystem == \"\(Constants.bundleIdentifier)\" AND category == \"\(category)\""
        ]
        process.standardOutput = output
        try process.run()
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 0)
        return try JSONDecoder().decode([LogEntry].self, from: output.fileHandleForReading.readDataToEndOfFile())
    }

    private struct LogEntry: Decodable {
        let formatString: String
        let eventMessage: String
    }
}
