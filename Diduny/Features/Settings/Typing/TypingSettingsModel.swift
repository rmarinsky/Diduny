import AppKit
import Observation
import SwiftUI
import PapugaKit

/// What stops fixes while typing; the Typing page shows one row for it, or none.
enum TypingStatus: Equatable {
    case accessibilityNeeded
    /// The setting is on and Accessibility is granted, but the system refused the key event tap.
    case startFailed
    /// A standalone Papuga is running, so Diduny's engine waits.
    case papugaRunning

    static func current(accessibilityGranted: Bool, hostState: TypingEngineHost.State) -> TypingStatus? {
        if !accessibilityGranted { return .accessibilityNeeded }
        switch hostState {
        case .startFailed: return .startFailed
        case .papugaRunning: return .papugaRunning
        case .stopped, .running: return nil
        }
    }
}

/// Settings > Typing > Layout fixes. Reads and writes the `typing.` keys of `SettingsStorage`; every change is
/// written at once and the engine host follows through `.typingSettingsChanged`.
@MainActor
@Observable
final class TypingSettingsModel {
    struct App: Equatable {
        let bundleID: String
        let name: String
    }

    @ObservationIgnored private let store: SettingsStorage
    @ObservationIgnored private let host: TypingEngineHost
    @ObservationIgnored private let isAccessibilityGranted: () -> Bool
    @ObservationIgnored private let runningApps: () -> [App]
    @ObservationIgnored private let installedAppName: (String) -> String?

    private(set) var enabled = false
    private(set) var sensitivity: AutoFixSensitivityPreset = .balanced
    private(set) var switchLayoutAfterFix = true
    private(set) var undoHintEnabled = true
    private(set) var learnVocabulary = true
    /// Bundle IDs, in the order they were added.
    private(set) var disabledApps: [String] = []
    private(set) var typingSpeedWordsPerMinute: Double = 0
    private(set) var accessibilityGranted = true
    /// The running apps, then the chosen ones that are not running; read by `reload()`.
    private(set) var apps: [App] = []

    init(
        store: SettingsStorage = .shared,
        host: TypingEngineHost = .shared,
        isAccessibilityGranted: @escaping () -> Bool = ClipboardService.isAccessibilityGranted,
        runningApps: @escaping () -> [App] = TypingSettingsModel.regularRunningApps,
        installedAppName: @escaping (String) -> String? = TypingSettingsModel.installedAppName
    ) {
        self.store = store
        self.host = host
        self.isAccessibilityGranted = isAccessibilityGranted
        self.runningApps = runningApps
        self.installedAppName = installedAppName
        reload()
    }

    func reload() {
        enabled = store.typingEnabled
        sensitivity = store.typingSensitivity
        switchLayoutAfterFix = store.typingSwitchLayoutAfterFix
        undoHintEnabled = store.typingUndoHintEnabled
        learnVocabulary = store.typingLearnVocabulary
        disabledApps = store.typingDisabledApps
        typingSpeedWordsPerMinute = store.typingSpeedWordsPerMinute
        accessibilityGranted = isAccessibilityGranted()
        reloadApps()
    }

    // MARK: - Status

    /// Reading `host.state` here makes the page follow the host by itself.
    var status: TypingStatus? {
        TypingStatus.current(accessibilityGranted: accessibilityGranted, hostState: host.state)
    }

    /// The page calls this every second while it is open: Accessibility changes in System Settings while
    /// Diduny is not the active app, and nothing announces it.
    func refreshAccessibility() {
        let granted = isAccessibilityGranted()
        guard granted != accessibilityGranted else { return }
        accessibilityGranted = granted
        host.reconcile()
    }

    func tryAgain() {
        host.reconcile()
    }

    /// "How often to fix", the layout switch and the undo hint do nothing while fixes are off.
    var optionsDisabled: Bool {
        !enabled
    }

    // MARK: - Settings

    func setEnabled(_ value: Bool) {
        store.typingEnabled = value
        enabled = value
    }

    func setSensitivity(_ value: AutoFixSensitivityPreset) {
        store.typingSensitivity = value
        sensitivity = value
    }

    func setSwitchLayoutAfterFix(_ value: Bool) {
        store.typingSwitchLayoutAfterFix = value
        switchLayoutAfterFix = value
    }

    func setUndoHintEnabled(_ value: Bool) {
        store.typingUndoHintEnabled = value
        undoHintEnabled = value
    }

    /// Off also deletes the typed-word counters (spec 03, 4.4).
    func setLearnVocabulary(_ value: Bool, vocabulary: VocabularyStore = .shared) {
        store.typingLearnVocabulary = value
        learnVocabulary = value
        if !value { vocabulary.clearTypedEvidence() }
    }

    /// "{n} of 300", plus what waits on the Vocabulary page.
    static func vocabularyCount(terms: Int, waiting: Int) -> LocalizedStringKey {
        waiting == 0 ? "\(terms) of 300" : "\(terms) of 300, \(waiting) waiting for you"
    }

    // MARK: - Apps

    /// Every bundle ID the popup lists: the running apps, then the chosen ones that are not running.
    var appIDs: [String] {
        apps.map(\.bundleID)
    }

    /// The app's name; the bundle ID when the app is neither running nor installed.
    func appName(_ bundleID: String) -> String {
        apps.first { $0.bundleID == bundleID }?.name ?? bundleID
    }

    var appsCaption: String {
        Self.appsCaption(disabledApps.map(appName))
    }

    static func appsCaption(_ names: [String]) -> String {
        names.isEmpty ? String(localized: "Fixes work in every app.") : names.joined(separator: ", ")
    }

    func toggleApp(_ bundleID: String) {
        var chosen = disabledApps
        if let index = chosen.firstIndex(of: bundleID) {
            chosen.remove(at: index)
        } else {
            chosen.append(bundleID)
        }
        store.typingDisabledApps = chosen
        disabledApps = chosen
    }

    private func reloadApps() {
        var seen = Set<String>()
        var list = runningApps().filter { seen.insert($0.bundleID).inserted }
        for bundleID in disabledApps where seen.insert(bundleID).inserted {
            list.append(App(bundleID: bundleID, name: installedAppName(bundleID) ?? bundleID))
        }
        apps = list
    }

    nonisolated static func regularRunningApps() -> [App] {
        NSWorkspace.shared.runningApplications.compactMap { app in
            guard app.activationPolicy == .regular, let bundleID = app.bundleIdentifier else { return nil }
            return App(bundleID: bundleID, name: app.localizedName ?? bundleID)
        }
    }

    nonisolated static func installedAppName(_ bundleID: String) -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }
}
