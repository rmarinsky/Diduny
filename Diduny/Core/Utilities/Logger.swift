import Foundation
import os

// MARK: - Logging

/// Centralized logging using Apple's unified logging system (os.Logger).
///
/// Log levels (use appropriately):
/// - `.debug()` - Detailed information for debugging, not shown in production
/// - `.info()` - General informational messages about normal flow
/// - `.warning()` - Non-fatal issues that should be noted (e.g., permission denied, retrying)
/// - `.error()` - Actual errors indicating failures
///
/// Categories:
/// - `app` - General app lifecycle and orchestration
/// - `recording` - Recording session management
/// - `transcription` - Soniox API and transcription flow
/// - `audio` - Audio device and capture operations
/// - `permissions` - Permission requests and checks
enum Log {
    private static let subsystem = "ua.com.rmarinsky.diduny"

    static let app = Logger(subsystem: subsystem, category: "app")
    static let recording = Logger(subsystem: subsystem, category: "recording")
    static let transcription = Logger(subsystem: subsystem, category: "transcription")
    static let audio = Logger(subsystem: subsystem, category: "audio")
    static let permissions = Logger(subsystem: subsystem, category: "permissions")
    static let whisper = Logger(subsystem: subsystem, category: "whisper")
    static let playback = Logger(subsystem: subsystem, category: "playback")
}

// MARK: - Dev Recording Debug Logs

enum RecordingDebugScope {
    @TaskLocal static var recordingID: UUID?
}

enum RecordingDebugCategory: String, CaseIterable {
    case app = "app"
    case decision = "decision"
    case http = "http"

    var title: String {
        switch self {
        case .app: "App"
        case .decision: "Decision"
        case .http: "HTTP"
        }
    }
}

struct RecordingDebugEntry: Identifiable {
    let id: UUID
    let timestamp: Date
    let category: RecordingDebugCategory
    let source: String?
    let message: String
}

actor RecordingDebugStore {
    static let shared = RecordingDebugStore()

    private var entriesByRecording: [UUID: [RecordingDebugEntry]] = [:]
    private let maxEntriesPerRecording = 300

    func append(
        recordingID: UUID?,
        category: RecordingDebugCategory,
        message: String,
        source: String? = nil
    ) {
#if DEBUG
        guard let recordingID else { return }
        var entries = entriesByRecording[recordingID] ?? []
        let sanitized = message.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sanitized.isEmpty else { return }

        entries.append(
            RecordingDebugEntry(
                id: UUID(),
                timestamp: Date(),
                category: category,
                source: source,
                message: String(sanitized.prefix(1000))
            )
        )

        if entries.count > maxEntriesPerRecording {
            entries.removeFirst(entries.count - maxEntriesPerRecording)
        }
        entriesByRecording[recordingID] = entries
#else
        _ = recordingID
        _ = category
        _ = message
        _ = source
#endif
    }

    func entries(for recordingID: UUID) -> [RecordingDebugEntry] {
#if DEBUG
        entriesByRecording[recordingID] ?? []
#else
        _ = recordingID
        return []
#endif
    }

    func clear(for recordingID: UUID) {
#if DEBUG
        entriesByRecording.removeValue(forKey: recordingID)
#else
        _ = recordingID
#endif
    }
}

enum RecordingDebugLog {
    static func app(_ message: String, source: String? = nil) {
#if DEBUG
        let recordingID = RecordingDebugScope.recordingID
        Task {
            await RecordingDebugStore.shared.append(
                recordingID: recordingID,
                category: .app,
                message: message,
                source: source
            )
        }
#else
        _ = message
        _ = source
#endif
    }

    static func decision(_ message: String, source: String? = nil) {
#if DEBUG
        let recordingID = RecordingDebugScope.recordingID
        Task {
            await RecordingDebugStore.shared.append(
                recordingID: recordingID,
                category: .decision,
                message: message,
                source: source
            )
        }
#else
        _ = message
        _ = source
#endif
    }

    static func http(_ message: String, source: String? = nil) {
#if DEBUG
        let recordingID = RecordingDebugScope.recordingID
        Task {
            await RecordingDebugStore.shared.append(
                recordingID: recordingID,
                category: .http,
                message: message,
                source: source
            )
        }
#else
        _ = message
        _ = source
#endif
    }
}
