import Foundation

/// The four choices at the top of Notes settings.
enum NotesWriterGroup: String, CaseIterable, Identifiable {
    case local
    case subscription
    case cloud
    case off

    var id: String { rawValue }
}

/// The program or service that writes the notes. Local servers keep the transcript on this Mac;
/// the CLIs send it to their vendor under the user's account and need the user's approval first.
enum NotesWriterKind: String, CaseIterable, Identifiable {
    case off
    case ollama
    case lmStudio
    case openAICompatible
    case claudeCode
    case codex
    case gemini
    case apiKey

    var id: String { rawValue }

    static let localServers: [NotesWriterKind] = [.ollama, .lmStudio, .openAICompatible]
    static let subscriptionTools: [NotesWriterKind] = [.claudeCode, .codex, .gemini, .apiKey]

    var label: String {
        switch self {
        case .off: String(localized: "Nobody")
        case .ollama: "Ollama"
        case .lmStudio: "LM Studio"
        case .openAICompatible: String(localized: "Other OpenAI-compatible server")
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        case .gemini: "Gemini CLI"
        case .apiKey: String(localized: "API key")
        }
    }

    var isLocal: Bool { Self.localServers.contains(self) }
    var isCLI: Bool { self == .claudeCode || self == .codex || self == .gemini }

    var executableName: String? {
        switch self {
        case .claudeCode: "claude"
        case .codex: "codex"
        case .gemini: "gemini"
        default: nil
        }
    }

    var vendor: String {
        switch self {
        case .claudeCode: "Anthropic"
        case .codex: "OpenAI"
        case .gemini: "Google"
        default: ""
        }
    }

    var defaultAddress: String {
        switch self {
        case .ollama: "http://127.0.0.1:11434"
        case .lmStudio: "http://127.0.0.1:1234"
        case .openAICompatible: "http://127.0.0.1:8080"
        default: ""
        }
    }

    var downloadPage: URL? {
        switch self {
        case .ollama: URL(string: "https://ollama.com")
        case .lmStudio: URL(string: "https://lmstudio.ai")
        default: nil
        }
    }
}

enum NotesModelTier: String, CaseIterable, Identifiable {
    case standard, faster, capable

    var id: String { rawValue }

    var label: String {
        switch self {
        case .standard: String(localized: "Default for the app")
        case .faster: String(localized: "Faster and cheaper")
        case .capable: String(localized: "Most capable")
        }
    }

    var claudeAlias: String {
        switch self {
        case .standard: "sonnet"
        case .faster: "haiku"
        case .capable: "opus"
        }
    }

    var anthropicModel: String {
        switch self {
        case .standard: "claude-sonnet-5-5"
        case .faster: "claude-haiku-5-5"
        case .capable: "claude-opus-5-5"
        }
    }

    /// Codex keeps the user's configured model; the tier sets how hard it thinks.
    var codexEffort: String? {
        switch self {
        case .standard: nil
        case .faster: "low"
        case .capable: "high"
        }
    }
}

enum NotesAPIProvider: String, CaseIterable, Identifiable {
    case anthropic, openAI, other

    var id: String { rawValue }

    var label: String {
        switch self {
        case .anthropic: "Anthropic"
        case .openAI: "OpenAI"
        case .other: String(localized: "Other address")
        }
    }
}

enum NotesMeetingTiming: String, CaseIterable, Identifiable {
    case whenIdle, afterRecording, onRequest

    var id: String { rawValue }

    var label: String {
        switch self {
        case .whenIdle: String(localized: "When the Mac is idle")
        case .afterRecording: String(localized: "Right after the recording")
        case .onRequest: String(localized: "Only when I ask")
        }
    }
}

enum NotesVoiceTiming: String, CaseIterable, Identifiable {
    case onRequest, over2, over5

    var id: String { rawValue }

    var label: String {
        switch self {
        case .onRequest: String(localized: "Only when I ask")
        case .over2: String(localized: "When it is longer than 2 min")
        case .over5: String(localized: "When it is longer than 5 min")
        }
    }

    var minimumSeconds: TimeInterval? {
        switch self {
        case .onRequest: nil
        case .over2: 120
        case .over5: 300
        }
    }
}

enum NotesLanguage: String, CaseIterable, Identifiable {
    case same, ukrainian, english

    var id: String { rawValue }

    var label: String {
        switch self {
        case .same: String(localized: "Same as the recording")
        case .ukrainian: String(localized: "Ukrainian")
        case .english: String(localized: "English")
        }
    }

    var promptValue: String {
        switch self {
        case .same: "the language the transcript is mostly spoken in"
        case .ukrainian: "Ukrainian"
        case .english: "English"
        }
    }
}

enum NotesNoOwner: String, CaseIterable, Identifiable {
    case writeNoOwner, leaveOut

    var id: String { rawValue }

    var label: String {
        switch self {
        case .writeNoOwner: String(localized: "Write \"No owner\"")
        case .leaveOut: String(localized: "Leave the task out")
        }
    }
}

/// Stored in UserDefaults under `notes.*`. One set of values, shown on the Notes settings
/// page and, for meetings, again in Calendar & meetings.
enum NotesSettings {
    private static let defaults = UserDefaults.standard

    private static func value<T: RawRepresentable>(_ key: String, _ fallback: T) -> T where T.RawValue == String {
        defaults.string(forKey: "notes.\(key)").flatMap(T.init) ?? fallback
    }

    private static func set<T: RawRepresentable>(_ key: String, _ value: T) where T.RawValue == String {
        defaults.set(value.rawValue, forKey: "notes.\(key)")
    }

    private static func bool(_ key: String, _ fallback: Bool) -> Bool {
        defaults.object(forKey: "notes.\(key)") as? Bool ?? fallback
    }

    // MARK: - Who writes

    static var group: NotesWriterGroup {
        get { value("group", .off) }
        set { set("group", newValue) }
    }

    static var localServer: NotesWriterKind {
        get { value("localServer", .ollama) }
        set { set("localServer", newValue) }
    }

    static var subscriptionTool: NotesWriterKind {
        get { value("subscriptionTool", .claudeCode) }
        set { set("subscriptionTool", newValue) }
    }

    /// The writer that runs. Diduny cloud has no writer yet, so it counts as nobody.
    static var writer: NotesWriterKind {
        switch group {
        case .local: localServer
        case .subscription: subscriptionTool
        case .cloud, .off: .off
        }
    }

    static func address(for kind: NotesWriterKind) -> String {
        defaults.string(forKey: "notes.address.\(kind.rawValue)")?.nilIfBlank ?? kind.defaultAddress
    }

    static func setAddress(_ value: String, for kind: NotesWriterKind) {
        defaults.set(value, forKey: "notes.address.\(kind.rawValue)")
    }

    /// Model name for a local server or an OpenAI-style API.
    static func model(for kind: NotesWriterKind) -> String {
        defaults.string(forKey: "notes.model.\(kind.rawValue)") ?? ""
    }

    static func setModel(_ value: String, for kind: NotesWriterKind) {
        defaults.set(value, forKey: "notes.model.\(kind.rawValue)")
    }

    static func tier(for kind: NotesWriterKind) -> NotesModelTier {
        value("tier.\(kind.rawValue)", .standard)
    }

    static func setTier(_ tier: NotesModelTier, for kind: NotesWriterKind) {
        set("tier.\(kind.rawValue)", tier)
    }

    static var apiProvider: NotesAPIProvider {
        get { value("apiProvider", .anthropic) }
        set { set("apiProvider", newValue) }
    }

    static var apiAddress: String {
        get { defaults.string(forKey: "notes.apiAddress") ?? "" }
        set { defaults.set(newValue, forKey: "notes.apiAddress") }
    }

    private static let apiKeyAccount = "notes.apiKey"

    static var apiKey: String? {
        get { KeychainManager.shared.read(key: apiKeyAccount)?.nilIfBlank }
        set {
            if let newValue = newValue?.nilIfBlank {
                try? KeychainManager.shared.save(key: apiKeyAccount, value: newValue)
            } else {
                KeychainManager.shared.delete(key: apiKeyAccount)
            }
        }
    }

    // MARK: - When

    static var meetingTiming: NotesMeetingTiming {
        get { value("meetingTiming2", .onRequest) }
        set {
            let wasOn = meetingTiming != .onRequest
            set("meetingTiming2", newValue)
            if newValue == .onRequest { meetingAutoSince = nil } else if !wasOn || meetingAutoSince == nil { meetingAutoSince = Date() }
        }
    }

    static var voiceTiming: NotesVoiceTiming {
        get { value("voiceTiming2", .onRequest) }
        set {
            let wasOn = voiceTiming != .onRequest
            set("voiceTiming2", newValue)
            if newValue == .onRequest { voiceAutoSince = nil } else if !wasOn || voiceAutoSince == nil { voiceAutoSince = Date() }
        }
    }

    /// Automatic notes cover only recordings made after they were turned on, separately for
    /// meetings and voice notes, so turning one on never sends earlier recordings of that kind.
    static var meetingAutoSince: Date? {
        get { defaults.object(forKey: "notes.meetingAutoSince") as? Date }
        set { defaults.set(newValue, forKey: "notes.meetingAutoSince") }
    }

    static var voiceAutoSince: Date? {
        get { defaults.object(forKey: "notes.voiceAutoSince") as? Date }
        set { defaults.set(newValue, forKey: "notes.voiceAutoSince") }
    }

    /// v2.20.0 kept one date for both kinds, which let old voice notes through. Each kind
    /// that is on starts from now instead; earlier ones go through Earlier recordings.
    static func migrateAutoDates() {
        guard defaults.object(forKey: "notes.autoSince") != nil else { return }
        defaults.removeObject(forKey: "notes.autoSince")
        if meetingTiming != .onRequest, meetingAutoSince == nil { meetingAutoSince = Date() }
        if voiceTiming != .onRequest, voiceAutoSince == nil { voiceAutoSince = Date() }
    }

    static var waitForPower: Bool {
        get { bool("waitForPower", true) }
        set { defaults.set(newValue, forKey: "notes.waitForPower") }
    }

    static var notifyWhenReady: Bool {
        get { bool("notify", false) }
        set { defaults.set(newValue, forKey: "notes.notify") }
    }

    // MARK: - Contents

    static var meetingTemplate: NotesTemplate {
        get { value("meetingTemplate", .meeting) }
        set { set("meetingTemplate", newValue) }
    }

    static var sections: Set<NotesSection> {
        get {
            guard let raw = defaults.stringArray(forKey: "notes.sections") else {
                return [.summary, .decisions, .actionItems, .openQuestions]
            }
            return Set(raw.compactMap(NotesSection.init))
        }
        set { defaults.set(newValue.map(\.rawValue), forKey: "notes.sections") }
    }

    static var language: NotesLanguage {
        get { value("language2", .same) }
        set { set("language2", newValue) }
    }

    static var length: NotesLength {
        get { value("length", .standard) }
        set { set("length", newValue) }
    }

    static var terms: String {
        get { defaults.string(forKey: "notes.terms") ?? "" }
        set { defaults.set(newValue, forKey: "notes.terms") }
    }

    static var useCalendarNames: Bool {
        get { bool("calendarNames", true) }
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

    // MARK: - Checking

    static var checkAgainstTranscript: Bool {
        get { bool("check", false) }
        set { defaults.set(newValue, forKey: "notes.check") }
    }

    static var showTimes: Bool {
        get { bool("showTimes", true) }
        set { defaults.set(newValue, forKey: "notes.showTimes") }
    }

    static var noOwner: NotesNoOwner {
        get { value("noOwner", .writeNoOwner) }
        set { set("noOwner", newValue) }
    }

    static var markUnknownNames: Bool {
        get { bool("markUnknownNames", true) }
        set { defaults.set(newValue, forKey: "notes.markUnknownNames") }
    }

    // MARK: - Last run

    struct LastRun: Codable {
        var seconds: Int
        var recordingMinutes: Int
        var writer: String
        var recordingID: UUID?
    }

    static func lastRun(for kind: NotesWriterKind) -> LastRun? {
        defaults.data(forKey: "notes.lastRun.\(kind.rawValue)").flatMap { try? JSONDecoder().decode(LastRun.self, from: $0) }
    }

    static func setLastRun(recording: Recording, seconds: Int, writer: String, for kind: NotesWriterKind) {
        let run = LastRun(seconds: seconds, recordingMinutes: max(1, Int(recording.effectiveDurationSeconds / 60)),
                          writer: writer, recordingID: recording.id)
        defaults.set(try? JSONEncoder().encode(run), forKey: "notes.lastRun.\(kind.rawValue)")
    }

    /// Seconds per recording minute from the last run, used for time estimates.
    static func secondsPerMinute(for kind: NotesWriterKind) -> Double? {
        lastRun(for: kind).map { Double($0.seconds) / Double($0.recordingMinutes) }
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
    }

    /// A user-chosen location for the CLI when it is not on the login shell's PATH.
    static func customExecutablePath(for kind: NotesWriterKind) -> String? {
        defaults.string(forKey: "notes.path.\(kind.rawValue)")?.nilIfBlank
    }

    static func setCustomExecutablePath(_ value: String?, for kind: NotesWriterKind) {
        defaults.set(value, forKey: "notes.path.\(kind.rawValue)")
    }

    /// Settings from the first build (a single "notes.writer" value) move to the new layout once.
    static func migrate() {
        guard let old = defaults.string(forKey: "notes.writer").flatMap(NotesWriterKind.init) else { return }
        defaults.removeObject(forKey: "notes.writer")
        if old.isLocal {
            group = .local
            localServer = old
        } else if old.isCLI {
            group = .subscription
            subscriptionTool = old
        }
    }
}
