import Foundation

/// The CLI shares `Recording` with the app; this stands in for the YouTube source type,
/// which lives in the app's networking code. Only its provider name is used by the model.
enum YouTubeRemoteMediaSource {
    static let provider = "youtube"
}

/// Read-only access to the Diduny library. Never writes to it.
struct Library {
    let directory: URL
    let bundleIdentifier: String

    /// The bundle this tool ships in decides which library it reads: the release app reads
    /// `ua.com.rmarinsky.diduny`, DEV reads `ua.com.rmarinsky.diduny.dev`.
    /// `DIDUNY_LIBRARY` or `--library` points at another folder.
    static func locate(override: String?) -> Library {
        let bundleID = enclosingAppBundleIdentifier() ?? "ua.com.rmarinsky.diduny"
        if let path = override ?? ProcessInfo.processInfo.environment["DIDUNY_LIBRARY"] {
            return Library(directory: URL(fileURLWithPath: (path as NSString).expandingTildeInPath), bundleIdentifier: bundleID)
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return Library(directory: support.appendingPathComponent(bundleID), bundleIdentifier: bundleID)
    }

    /// `Diduny.app/Contents/Helpers/diduny`, reached directly or through a symlink in PATH.
    static func enclosingAppBundleIdentifier() -> String? {
        enclosingAppURL().flatMap { Bundle(url: $0)?.bundleIdentifier }
    }

    /// The app this binary ships in. Uses the kernel's path of the running executable, not
    /// `argv[0]`: a shell that finds `diduny-dev` through PATH passes just the name, which
    /// would make the DEV tool read the release library and settings.
    static func enclosingAppURL() -> URL? {
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        var buffer = [CChar](repeating: 0, count: Int(size))
        guard _NSGetExecutablePath(&buffer, &size) == 0 else { return nil }
        let executable = URL(fileURLWithPath: String(cString: buffer)).resolvingSymlinksInPath()
        let app = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return app.pathExtension == "app" ? app : nil
    }

    var metadataURL: URL { directory.appendingPathComponent("recordings_metadata.json") }

    func load() throws -> [Recording] {
        guard FileManager.default.fileExists(atPath: metadataURL.path) else {
            throw CLIError("No Diduny library at \(directory.path). Record something in Diduny first, or pass --library <folder>.")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode([Recording].self, from: Data(contentsOf: metadataURL))
                .sorted { $0.createdAt > $1.createdAt }
        } catch {
            throw CLIError("Could not read \(metadataURL.path). It may come from a newer Diduny than this tool.")
        }
    }

    func audioURL(_ recording: Recording) -> URL {
        directory.appendingPathComponent("Recordings").appendingPathComponent(recording.audioFileName)
    }

    /// `latest`, a full id, or the first characters of one (as `meetings list` prints).
    func find(_ reference: String, in recordings: [Recording]) throws -> Recording {
        if reference == "latest" {
            guard let first = recordings.first else { throw CLIError("No recordings match.") }
            return first
        }
        let prefix = reference.lowercased()
        let matches = recordings.filter { $0.id.uuidString.lowercased().hasPrefix(prefix) }
        guard let match = matches.first else { throw CLIError("No recording with id \(reference).") }
        guard matches.count == 1 else { throw CLIError("\(reference) matches \(matches.count) recordings; use more characters.") }
        return match
    }
}

struct CLIError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// Which recordings a command covers. Meetings by default.
enum TypeFilter: String, CaseIterable {
    case meetings, voice, translations, files, all

    func includes(_ type: Recording.RecordingType) -> Bool {
        switch self {
        case .meetings: type == .meeting || type == .meetingTranslation
        case .voice: type == .voice
        case .translations: type == .translation || type == .meetingTranslation
        case .files: type == .fileTranscription
        case .all: true
        }
    }
}

/// "7d", "24h", "2w", or a date like 2026-11-01.
func parseSince(_ text: String) throws -> Date {
    let units: [Character: Double] = ["h": 3600, "d": 86400, "w": 604_800]
    if let unit = text.last, let seconds = units[unit], let count = Double(text.dropLast()) {
        return Date().addingTimeInterval(-count * seconds)
    }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd"
    if let date = formatter.date(from: text) { return date }
    throw CLIError("--since takes 24h, 7d, 2w or a date like 2026-11-01.")
}
