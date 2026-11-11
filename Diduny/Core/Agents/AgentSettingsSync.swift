import Foundation
import os

/// Keeps `~/.config/diduny/settings.json` and UserDefaults in step for the keys in
/// `AgentSettings`. UserDefaults stays the store; the file is a copy agents may edit.
///
/// - At launch and whenever Diduny changes a listed setting, the file is rewritten with the
///   values in use.
/// - When the file changes on disk (an agent or `diduny settings set`), valid values are
///   applied, invalid ones are listed under "problems", and the file is rewritten.
/// - A file edited while Diduny was closed is applied at the next launch.
@MainActor
final class AgentSettingsSync {
    static let shared = AgentSettingsSync()

    private let logger = Logger(subsystem: "ua.com.rmarinsky.diduny", category: "Agents")
    private let url = AgentSettings.fileURL(bundleIdentifier: Bundle.main.bundleIdentifier ?? "ua.com.rmarinsky.diduny")
    private let lastWrittenKey = "agents.settingsFile.lastWritten"
    private var source: DispatchSourceFileSystemObject?
    private var defaultsObserver: NSObjectProtocol?
    private var pendingCheck: DispatchWorkItem?
    private var pendingFileChange = false
    private var lastProblems: [String] = []

    var fileURL: URL { url }

    func start() {
        // An edit made while Diduny was closed differs from what Diduny last wrote.
        if let data = try? Data(contentsOf: url), data != lastWritten {
            applyFile()
        } else {
            writeFile()
        }
        watch()
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleCheck(fileChanged: false) }
        }
    }

    // MARK: - Values

    /// Current values from SettingsStorage, as JSON values.
    static func currentValues() -> [String: Any] {
        let storage = SettingsStorage.shared
        return [
            "whisperPrompt": storage.whisperPrompt,
            "whisperLanguage": storage.whisperLanguage,
            "speechLanguages": storage.manualSpeechLanguageHints,
            "translationTargetLanguages": storage.translationTargetLanguages,
            "fillerWords": storage.fillerWords,
            "messageFormattingMode": storage.messageFormattingMode.rawValue,
            "dictationSilenceAutoStopEnabled": storage.dictationSilenceAutoStopEnabled,
            "dictationSilenceAutoStopSeconds": storage.dictationSilenceAutoStopSeconds,
            "meetingSilenceAutoStopEnabled": storage.meetingSilenceAutoStopEnabled,
            "meetingSilenceAutoStopSeconds": storage.meetingSilenceAutoStopSeconds,
            "speakerIdentificationEnabled": storage.speakerIdentificationEnabled,
            "playSoundOnCompletion": storage.playSoundOnCompletion
        ]
    }

    /// Writes one validated value through SettingsStorage, so the app reacts as if the user
    /// changed it in Settings.
    static func apply(_ name: String, _ value: Any) {
        let storage = SettingsStorage.shared
        switch name {
        case "whisperPrompt": if let text = value as? String { storage.whisperPrompt = text }
        case "whisperLanguage": if let code = value as? String { storage.whisperLanguage = code }
        case "speechLanguages": if let codes = value as? [String] { storage.manualSpeechLanguageHints = codes }
        case "translationTargetLanguages": if let codes = value as? [String], !codes.isEmpty { storage.translationTargetLanguages = codes }
        case "fillerWords": if let words = value as? [String] { storage.fillerWords = words }
        case "messageFormattingMode":
            if let raw = value as? String, let mode = MessageFormattingMode(rawValue: raw) { storage.messageFormattingMode = mode }
        case "dictationSilenceAutoStopEnabled": if let flag = value as? Bool { storage.dictationSilenceAutoStopEnabled = flag }
        case "dictationSilenceAutoStopSeconds": if let number = value as? Double { storage.dictationSilenceAutoStopSeconds = number }
        case "meetingSilenceAutoStopEnabled": if let flag = value as? Bool { storage.meetingSilenceAutoStopEnabled = flag }
        case "meetingSilenceAutoStopSeconds": if let number = value as? Double { storage.meetingSilenceAutoStopSeconds = number }
        case "speakerIdentificationEnabled": if let flag = value as? Bool { storage.speakerIdentificationEnabled = flag }
        case "playSoundOnCompletion": if let flag = value as? Bool { storage.playSoundOnCompletion = flag }
        default: break
        }
    }

    /// Validates every key of an edited file and applies the valid ones that differ.
    /// Returns the problems, one line each.
    static func applyEdits(_ settings: [String: Any], current: [String: Any]) -> [String] {
        var problems: [String] = []
        for (name, raw) in settings {
            switch AgentSettings.validate(name, raw) {
            case let .success(value):
                if !Self.same(value, current[name]) { apply(name, value) }
            case let .failure(error):
                problems.append(error.description)
            }
        }
        return problems.sorted()
    }

    static func same(_ lhs: Any, _ rhs: Any?) -> Bool {
        guard let rhs else { return false }
        return (lhs as AnyObject).isEqual(rhs)
    }

    // MARK: - File

    private var lastWritten: Data? {
        get { UserDefaults.standard.data(forKey: lastWrittenKey) }
        set { UserDefaults.standard.set(newValue, forKey: lastWrittenKey) }
    }

    private func applyFile() {
        guard let data = try? Data(contentsOf: url) else { return writeFile() }
        guard data != lastWritten else { return }
        guard let settings = AgentSettings.readSettings(at: url) else {
            lastProblems = ["The file is not valid JSON with a \"settings\" object, so it was rewritten with the settings in use."]
            logger.error("Agent settings file was not readable; rewriting it")
            return writeFile()
        }
        lastProblems = Self.applyEdits(settings, current: Self.currentValues())
        if !lastProblems.isEmpty { logger.info("Agent settings: \(self.lastProblems.count) values ignored") }
        writeFile()
    }

    private func writeFile() {
        let data = AgentSettings.fileData(settings: Self.currentValues(), problems: lastProblems)
        guard data != (try? Data(contentsOf: url)) else {
            // Setting UserDefaults posts didChangeNotification, which calls this again, so only
            // a real change may write it.
            if lastWritten != data { lastWritten = data }
            return
        }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            lastWritten = data
            try data.write(to: url, options: .atomic)
        } catch {
            logger.error("Could not write the agent settings file")
        }
    }

    /// Watches the folder: editors and `diduny settings set` replace the file atomically,
    /// which a watch on the file itself would lose.
    private func watch() {
        let folder = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let descriptor = open(folder.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.scheduleCheck(fileChanged: true) }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        self.source = source
    }

    /// Coalesces bursts of events (an editor saves in several steps; one settings change can
    /// post several UserDefaults notifications).
    /// A file edit seen in the burst wins over a settings change, so an edit is never lost.
    private func scheduleCheck(fileChanged: Bool) {
        pendingFileChange = pendingFileChange || fileChanged
        pendingCheck?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let fileChanged = pendingFileChange
            pendingFileChange = false
            if fileChanged { applyFile() } else { writeFile() }
        }
        pendingCheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }
}
