import Foundation

/// Who writes the notes. Local servers keep the transcript on this Mac; the CLIs send it
/// to the vendor under the user's own account and need the user's approval first.
enum NotesWriterKind: String, CaseIterable, Identifiable {
    case off
    case ollama
    case lmStudio
    case claudeCode
    case codex

    var id: String { rawValue }

    var label: String {
        switch self {
        case .off: String(localized: "Nobody")
        case .ollama: "Ollama"
        case .lmStudio: "LM Studio"
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        }
    }

    var isLocal: Bool { self == .ollama || self == .lmStudio }
    var isCLI: Bool { self == .claudeCode || self == .codex }

    var executableName: String? {
        switch self {
        case .claudeCode: "claude"
        case .codex: "codex"
        default: nil
        }
    }

    var vendor: String {
        switch self {
        case .claudeCode: "Anthropic"
        case .codex: "OpenAI"
        default: ""
        }
    }

    var defaultAddress: String {
        switch self {
        case .ollama: "http://127.0.0.1:11434"
        case .lmStudio: "http://127.0.0.1:1234"
        default: ""
        }
    }
}

enum NotesTiming: String, CaseIterable, Identifiable {
    case afterTranscript
    case onRequest

    var id: String { rawValue }

    var label: String {
        switch self {
        case .afterTranscript: String(localized: "Right after the transcript is ready")
        case .onRequest: String(localized: "Only when I ask")
        }
    }
}

/// Stored in UserDefaults under `notes.*`. One set of values, shown on the Notes settings
/// page and, for meetings, again in Calendar & meetings.
enum NotesSettings {
    private static let defaults = UserDefaults.standard

    static var writer: NotesWriterKind {
        get { defaults.string(forKey: "notes.writer").flatMap(NotesWriterKind.init) ?? .off }
        set { defaults.set(newValue.rawValue, forKey: "notes.writer") }
    }

    static var meetingTiming: NotesTiming {
        get { defaults.string(forKey: "notes.meetingTiming").flatMap(NotesTiming.init) ?? .onRequest }
        set {
            defaults.set(newValue.rawValue, forKey: "notes.meetingTiming")
            if newValue == .afterTranscript { autoNotesSince = autoNotesSince ?? Date() }
        }
    }

    static var voiceTiming: NotesTiming {
        get { defaults.string(forKey: "notes.voiceTiming").flatMap(NotesTiming.init) ?? .onRequest }
        set {
            defaults.set(newValue.rawValue, forKey: "notes.voiceTiming")
            if newValue == .afterTranscript { autoNotesSince = autoNotesSince ?? Date() }
        }
    }

    /// Automatic notes cover only recordings made after they were turned on, so turning
    /// them on never sends the whole library to a model.
    static var autoNotesSince: Date? {
        get { defaults.object(forKey: "notes.autoSince") as? Date }
        set { defaults.set(newValue, forKey: "notes.autoSince") }
    }

    static func address(for kind: NotesWriterKind) -> String {
        defaults.string(forKey: "notes.address.\(kind.rawValue)")?.nilIfBlank ?? kind.defaultAddress
    }

    static func setAddress(_ value: String, for kind: NotesWriterKind) {
        defaults.set(value, forKey: "notes.address.\(kind.rawValue)")
    }

    /// Model name for a local server, or the model alias for a CLI (empty = the CLI's default).
    static func model(for kind: NotesWriterKind) -> String {
        defaults.string(forKey: "notes.model.\(kind.rawValue)") ?? (kind == .claudeCode ? "sonnet" : "")
    }

    static func setModel(_ value: String, for kind: NotesWriterKind) {
        defaults.set(value, forKey: "notes.model.\(kind.rawValue)")
    }

    static var language: String {
        get { defaults.string(forKey: "notes.language") ?? "" }
        set { defaults.set(newValue, forKey: "notes.language") }
    }

    static var terms: String {
        get { defaults.string(forKey: "notes.terms") ?? "" }
        set { defaults.set(newValue, forKey: "notes.terms") }
    }

    static var useCalendarNames: Bool {
        get { defaults.object(forKey: "notes.calendarNames") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "notes.calendarNames") }
    }

    static func customPrompt(for template: NotesTemplate) -> String? {
        defaults.string(forKey: "notes.prompt.\(template.rawValue)")?.nilIfBlank
    }

    static func setCustomPrompt(_ value: String?, for template: NotesTemplate) {
        defaults.set(value, forKey: "notes.prompt.\(template.rawValue)")
    }

    static func prompt(for template: NotesTemplate) -> String {
        customPrompt(for: template) ?? template.defaultPrompt
    }

    // MARK: - CLI approval

    /// The user allowed this tool at this path. A different path asks again.
    static func approvedPath(for kind: NotesWriterKind) -> String? {
        defaults.string(forKey: "notes.approval.\(kind.rawValue).path")
    }

    static func approvalDate(for kind: NotesWriterKind) -> Date? {
        defaults.object(forKey: "notes.approval.\(kind.rawValue).date") as? Date
    }

    static func approve(_ kind: NotesWriterKind, path: String) {
        defaults.set(path, forKey: "notes.approval.\(kind.rawValue).path")
        defaults.set(Date(), forKey: "notes.approval.\(kind.rawValue).date")
    }

    static func revokeApproval(_ kind: NotesWriterKind) {
        defaults.removeObject(forKey: "notes.approval.\(kind.rawValue).path")
        defaults.removeObject(forKey: "notes.approval.\(kind.rawValue).date")
        if writer == kind { writer = .off }
    }

    /// A user-chosen location for the CLI when it is not on the login shell's PATH.
    static func customExecutablePath(for kind: NotesWriterKind) -> String? {
        defaults.string(forKey: "notes.path.\(kind.rawValue)")?.nilIfBlank
    }

    static func setCustomExecutablePath(_ value: String?, for kind: NotesWriterKind) {
        defaults.set(value, forKey: "notes.path.\(kind.rawValue)")
    }
}
