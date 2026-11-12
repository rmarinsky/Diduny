@testable import Diduny
import Foundation
import Testing

private enum SampleError: Error {
    case serverError(String)
    case timeout
}

/// An error whose description is the message: the code must not come from it.
private enum TalkativeError: Error, CustomStringConvertible {
    case failed
    var description: String { "the user's dictated sentence" }
}

private func tempDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("diagnostics-tests-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

struct DiagnosticLogTests {
    @Test("Only short tokens are kept: sentences, keys with spaces and long values are dropped")
    func dropsFreeText() throws {
        let line = try #require(DiagnosticLog.line(.failure, [
            .engine: "local-whisper:large-v3",
            .errorCode: "hello this is what I dictated",
            .path: .string(String(repeating: "a", count: 81)),
            .httpStatus: 502,
        ], at: Date(timeIntervalSince1970: 0)))
        #expect(line.contains("\"engine\":\"local-whisper:large-v3\""))
        #expect(line.contains("\"http_status\":502"))
        #expect(!line.contains("dictated"))
        #expect(!line.contains("aaaa"))
        #expect(!line.contains("\"error_code\""))
    }

    @Test("Error codes carry the type and case, never associated values")
    func errorCode() {
        #expect(DiagnosticLog.errorCode(SampleError.serverError("secret transcript")) == "SampleError.serverError")
        #expect(DiagnosticLog.errorCode(SampleError.timeout) == "SampleError.timeout")
        let fields = DiagnosticLog.errorFields(SampleError.serverError("secret transcript"))
        #expect(!String(describing: fields).contains("secret"))
        #expect(!DiagnosticLog.errorCode(TalkativeError.failed).contains("dictated"))
        #expect(DiagnosticLog.errorCode(TalkativeError.failed).hasPrefix("TalkativeError."))
    }

    @Test("Writes JSON lines, remembers the last request ID and rotates at the size limit")
    func writesAndRotates() throws {
        let directory = tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = DiagnosticLog(directory: directory)
        log.record(.httpError, [.httpStatus: 500, .requestId: "req-1"])
        log.flush()
        #expect(log.recentRequestId() == "req-1")
        let current = directory.appendingPathComponent(DiagnosticLog.fileName)
        let text = try String(contentsOf: current, encoding: .utf8)
        #expect(text.hasSuffix("\n"))
        #expect(text.contains("\"event\":\"http_error\""))

        try Data(count: DiagnosticLog.maxFileBytes).write(to: current)
        log.record(.appLaunch)
        log.flush()
        #expect(log.files().count == 2)
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("diagnostics.1.jsonl").path))
    }

    @Test("The export zip holds the log and the summary")
    @MainActor
    func exportArchive() async throws {
        let directory = tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = DiagnosticLog(directory: directory.appendingPathComponent("logs"))
        log.record(.appLaunch, [.appVersion: "1.2.3"])
        let zip = directory.appendingPathComponent("out.zip")
        try Data("previous".utf8).write(to: zip)
        try await DiagnosticsExporter.makeArchive(log: log, summary: ["appVersion": "1.2.3"], destination: zip)

        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-l", zip.path]
        let pipe = Pipe()
        unzip.standardOutput = pipe
        try unzip.run()
        unzip.waitUntilExit()
        let listing = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        #expect(listing.contains("out/diagnostics.jsonl"))
        #expect(listing.contains("out/summary.json"))
    }

    @Test("A failed zip leaves the file already at the destination as it was")
    func failedArchiveKeepsTheOldFile() throws {
        let directory = tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let zip = directory.appendingPathComponent("out.zip")
        try Data("previous".utf8).write(to: zip)
        #expect(throws: (any Error).self) {
            try DiagnosticsExporter.writeArchive(files: [], summary: Data("{}".utf8), destination: zip, ditto: "/usr/bin/false")
        }
        #expect(try String(contentsOf: zip, encoding: .utf8) == "previous")
    }
}

struct HTTPLoggerRouteTests {
    @Test("Failed calls keep the route, never ids or file names")
    func routeTemplate() {
        #expect(HTTPLogger.routeTemplate("/api/v1/jobs/7f3c2a/events") == "/api/v1/jobs/:x/events")
        #expect(HTTPLogger.routeTemplate("/recordings/private-call.wav") == "/:x/:x")
        #expect(HTTPLogger.routeTemplate("/api/v1/transcriptions") == "/api/v1/transcriptions")
        #expect(HTTPLogger.routeTemplate("") == "")
    }
}

@MainActor
struct FeatureUsageCounterTests {
    private func makeDefaults() -> UserDefaults {
        let name = "feature-usage-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test("Counts per day and sends finished days without any account field")
    func sendsFinishedDays() async throws {
        let defaults = makeDefaults()
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        var sent: [[String: Any]] = []
        let counter = FeatureUsageCounter(
            defaults: defaults,
            isEnabled: { true },
            isSignedIn: { true },
            baseURL: { "https://proxy.example" },
            transport: { request in
                #expect(request.url?.path == "/api/v1/feature-usage")
                sent.append(try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any] ?? [:])
                return (Data("{}".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            },
            now: { clock }
        )
        counter.record(.dictation, via: .hotkey)
        counter.record(.dictation, via: .hotkey)
        await counter.flush()
        #expect(sent.isEmpty) // today is not over yet

        clock = clock.addingTimeInterval(86400)
        await counter.flush()
        let batch = try #require(sent.first)
        #expect(batch["day"] as? String == FeatureUsageCounter.day(clock.addingTimeInterval(-86400)))
        let counts = try #require(batch["counts"] as? [[String: Any]])
        #expect(counts.first?["feature"] as? String == "dictation")
        #expect(counts.first?["trigger"] as? String == "hotkey")
        #expect(counts.first?["count"] as? Int == 2)
        #expect(Set(batch.keys) == ["appVersion", "day", "counts"])
        #expect(counter.pending.isEmpty)
    }

    @Test("Turned off: nothing is counted and pending days are dropped")
    func disabled() async {
        let defaults = makeDefaults()
        var enabled = true
        let counter = FeatureUsageCounter(
            defaults: defaults,
            isEnabled: { enabled },
            isSignedIn: { true },
            baseURL: { "https://proxy.example" },
            transport: { _ in
                Issue.record("must not send")
                throw URLError(.notConnectedToInternet)
            }
        )
        counter.record(.meeting, via: .menu)
        #expect(!counter.pending.isEmpty)
        enabled = false
        counter.record(.meeting, via: .menu)
        await counter.flush()
        #expect(counter.pending.isEmpty)
    }

    @Test("Signed out: counts stay on this Mac, nothing is sent")
    func signedOutSendsNothing() async {
        let defaults = makeDefaults()
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        let counter = FeatureUsageCounter(
            defaults: defaults,
            isEnabled: { true },
            isSignedIn: { false },
            baseURL: { "https://proxy.example" },
            transport: { _ in
                Issue.record("must not send while signed out")
                throw URLError(.userAuthenticationRequired)
            },
            now: { clock }
        )
        counter.record(.dictation, via: .hotkey)
        clock = clock.addingTimeInterval(86400)
        await counter.flush()
        #expect(!counter.pending.isEmpty)
    }

    @Test("Engine labels fit the backend alphabet")
    func engineLabel() {
        #expect(AnalyticsService.engineLabel("local-whisper:Large V3/Turbo") == "local-whisper:large-v3-turbo")
        #expect(AnalyticsService.engineLabel("-bad") == nil)
        #expect(AnalyticsService.engineLabel(String(repeating: "a", count: 100))?.count == 64)
    }
}
