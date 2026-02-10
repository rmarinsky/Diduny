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
