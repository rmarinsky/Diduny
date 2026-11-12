import Foundation

/// Rolling on-disk log of actions and errors, exported by the user for support.
///
/// Privacy by construction: an entry is an event name from `DiagnosticEvent` plus
/// values for keys from `DiagnosticField`. String values must be short tokens with
/// no spaces (codes, IDs, engine names), so transcripts, titles, file names or
/// messages cannot be written. Never pass keys or tokens as values.
enum DiagnosticEvent: String, Sendable {
    case appLaunch = "app_launch"
    case appTerminate = "app_terminate"
    case recordingStarted = "recording_started"
    case recordingStopped = "recording_stopped"
    case transcriptionSucceeded = "transcription_succeeded"
    case failure
    case httpError = "http_error"
    case featureUsed = "feature_used"
    case diagnosticsExported = "diagnostics_exported"
}

enum DiagnosticField: String, Sendable, CaseIterable {
    case kind, engine, mode, scenario, trigger, feature
    case status, httpStatus = "http_status", path
    case requestId = "request_id", jobId = "job_id", recordingId = "recording_id"
    case errorDomain = "error_domain", errorCode = "error_code"
    case durationMs = "duration_ms", count
    case appVersion = "app_version", osVersion = "os_version", arch
    case previousExit = "previous_exit"
}

enum DiagnosticValue: Sendable, Equatable {
    case string(String)
    case int(Int)
    case bool(Bool)
}

extension DiagnosticValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral {
    init(stringLiteral value: String) { self = .string(value) }
    init(integerLiteral value: Int) { self = .int(value) }
    init(booleanLiteral value: Bool) { self = .bool(value) }
}

final class DiagnosticLog: @unchecked Sendable {
    static let shared = DiagnosticLog(directory: DiagnosticLog.defaultDirectory)

    static let maxFileBytes = 1_000_000
    static let keptFiles = 5
    static let fileName = "diagnostics.jsonl"

    let directory: URL
    private let queue = DispatchQueue(label: "ua.com.rmarinsky.diduny.diagnostics")
    private let lock = NSLock()
    private var lastRequestId: (id: String, at: Date)?

    init(directory: URL) {
        self.directory = directory
    }

    static var defaultDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "Diduny")
            .appendingPathComponent("Diagnostics")
    }

    /// Only short tokens survive: letters, digits and `_ . : / -`, at most 80 characters.
    static func isSafeToken(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 80 else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || "_.:/-".unicodeScalars.contains(scalar))
        }
    }

    static func line(_ event: DiagnosticEvent, _ fields: [DiagnosticField: DiagnosticValue], at date: Date) -> String? {
        var object: [String: Any] = [
            "ts": ISO8601DateFormatter().string(from: date),
            "event": event.rawValue,
        ]
        for (key, value) in fields {
            switch value {
            case let .string(text):
                // A value that is not a short token is dropped, not truncated.
                if isSafeToken(text) { object[key.rawValue] = text }
            case let .int(number): object[key.rawValue] = number
            case let .bool(flag): object[key.rawValue] = flag
            }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    func record(_ event: DiagnosticEvent, _ fields: [DiagnosticField: DiagnosticValue] = [:]) {
        let date = Date()
        guard let line = Self.line(event, fields, at: date) else { return }
        if case let .string(id)? = fields[.requestId], Self.isSafeToken(id) {
            lock.withLock { lastRequestId = (id, date) }
        }
        queue.async { self.append(line + "\n") }
    }

    /// The server request ID of the last failed call within `window`, to attach to an error report.
    func recentRequestId(within window: TimeInterval = 120) -> String? {
        lock.withLock {
            guard let last = lastRequestId, Date().timeIntervalSince(last.at) <= window else { return nil }
            return last.id
        }
    }

    /// Current file first, then rotated ones (newest to oldest).
    func files() -> [URL] {
        queue.sync {
            ([directory.appendingPathComponent(Self.fileName)] + (1 ..< Self.keptFiles).map(rotated))
                .filter { FileManager.default.fileExists(atPath: $0.path) }
        }
    }

    /// Waits until queued writes reach the disk (tests and export).
    func flush() {
        queue.sync {}
    }

    private func rotated(_ index: Int) -> URL {
        directory.appendingPathComponent("diagnostics.\(index).jsonl")
    }

    private func append(_ text: String) {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let current = directory.appendingPathComponent(Self.fileName)
        if let size = (try? fm.attributesOfItem(atPath: current.path))?[.size] as? Int, size >= Self.maxFileBytes {
            try? fm.removeItem(at: rotated(Self.keptFiles - 1))
            for index in stride(from: Self.keptFiles - 2, through: 1, by: -1) {
                try? fm.moveItem(at: rotated(index), to: rotated(index + 1))
            }
            try? fm.moveItem(at: current, to: rotated(1))
        }
        guard let data = text.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: current) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: current, options: .atomic)
        }
    }
}

extension DiagnosticLog {
    /// Error identity without its message: `NSError` domain and code, plus the Swift type and case name.
    static func errorFields(_ error: Error) -> [DiagnosticField: DiagnosticValue] {
        let nsError = error as NSError
        return [
            .errorDomain: .string(nsError.domain),
            .errorCode: .string(errorCode(error)),
        ]
    }

    /// `TranscriptionError.serverError` → "TranscriptionError.serverError"; associated values are dropped.
    static func errorCode(_ error: Error) -> String {
        let type = String(describing: Swift.type(of: error))
        let mirror = Mirror(reflecting: error)
        // Never derived from a description: a type that describes itself could print its message.
        // A case with a payload names itself through the mirror; a case without one is named by
        // `String(describing:)` only when the type does not override its description.
        let describesItself = error is CustomStringConvertible || error is CustomDebugStringConvertible
        let caseName: String = if mirror.displayStyle == .enum, let label = mirror.children.first?.label {
            label
        } else if mirror.displayStyle == .enum, !describesItself {
            String(describing: error)
        } else {
            String((error as NSError).code)
        }
        let code = "\(type).\(caseName)"
        return isSafeToken(code) ? String(code.prefix(64)) : type
    }
}
