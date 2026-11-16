@testable import Diduny
import Foundation
import PapugaKit
import Testing

@MainActor
private final class StubTypingEngine: TypingEngineControlling {
    var starts = true
    func start() -> Bool { starts }
    func stop() {}
    func noteExternalEdit() {}
    func undoLastFix() {}
    func layoutConversion(of _: String) -> TypingLayoutConversion? { nil }
    func finishLayoutConversion(_: TypingLayoutConversion) {}
    func applyHistorySettings() {}
}

/// Settings > Typing > Layout fixes: the status row, the disabled rows and the apps list.
@MainActor
final class TypingSettingsModelTests {
    private typealias App = TypingSettingsModel.App

    private let box = IsolatedSettings("TypingSettingsModelTests")
    private let engine = StubTypingEngine()
    private var accessibility = true
    private var papugaRunning = false
    private var running: [App] = [App(bundleID: "com.apple.dt.Xcode", name: "Xcode"), App(bundleID: "com.apple.Safari", name: "Safari")]
    private lazy var host = TypingEngineHost(
        settings: box.settings, isAccessibilityGranted: { [unowned self] in accessibility },
        isPapugaRunning: { [unowned self] in papugaRunning }, makeEngine: { [unowned self] in engine }
    )

    private func model() -> TypingSettingsModel {
        TypingSettingsModel(
            store: box.settings, host: host,
            isAccessibilityGranted: { [unowned self] in accessibility },
            runningApps: { [unowned self] in running },
            installedAppName: { $0 == "com.mitchellh.ghostty" ? "Ghostty" : nil }
        )
    }

    // MARK: - Status row

    @Test("the status row for each permission and host state")
    func statusTable() {
        #expect(TypingStatus.current(accessibilityGranted: true, hostState: .stopped) == nil)
        #expect(TypingStatus.current(accessibilityGranted: true, hostState: .running) == nil)
        #expect(TypingStatus.current(accessibilityGranted: true, hostState: .startFailed) == .startFailed)
        #expect(TypingStatus.current(accessibilityGranted: true, hostState: .papugaRunning) == .papugaRunning)
        for state in [TypingEngineHost.State.stopped, .running, .startFailed, .papugaRunning] {
            #expect(TypingStatus.current(accessibilityGranted: false, hostState: state) == .accessibilityNeeded)
        }
    }

    @Test("no Accessibility: the row shows, and goes after the permission is given")
    func accessibilityRowFollowsThePermission() {
        accessibility = false
        let model = model()
        #expect(model.status == .accessibilityNeeded)

        accessibility = true
        model.reload()
        #expect(model.status == nil)
    }

    @Test("the row follows Accessibility without a reload, and the engine starts once it is given")
    func accessibilityRefreshWhileOpen() {
        accessibility = false
        let model = model()
        model.setEnabled(true)
        host.reconcile()
        #expect(model.status == .accessibilityNeeded)

        accessibility = true
        model.refreshAccessibility()
        #expect(model.status == nil)
        #expect(host.state == .running)

        accessibility = false
        model.refreshAccessibility()
        #expect(model.status == .accessibilityNeeded)
        #expect(host.state == .stopped)
    }

    @Test("a running Papuga shows its row, which goes when Papuga quits")
    func papugaRowFollowsTheHost() {
        papugaRunning = true
        let model = model()
        model.setEnabled(true)
        host.reconcile()
        #expect(model.status == .papugaRunning)

        papugaRunning = false
        host.reconcile()
        #expect(model.status == nil)
    }

    @Test("a refused key tap shows Try again, which starts the engine once the tap is allowed")
    func tryAgainReconciles() {
        engine.starts = false
        let model = model()
        model.setEnabled(true)
        host.reconcile()
        #expect(model.status == .startFailed)

        engine.starts = true
        model.tryAgain()
        #expect(host.state == .running)
        #expect(model.status == nil)
    }

    // MARK: - Settings

    @Test("every control writes its typing. key at once")
    func writes() {
        let model = model()
        #expect(model.optionsDisabled)

        model.setEnabled(true)
        model.setSensitivity(.moreHints)
        model.setSwitchLayoutAfterFix(false)
        model.setUndoHintEnabled(false)

        #expect(!model.optionsDisabled)
        #expect(box.settings.typingEnabled)
        #expect(box.settings.typingSensitivity == .moreHints)
        #expect(!box.settings.typingSwitchLayoutAfterFix)
        #expect(!box.settings.typingUndoHintEnabled)

        let reopened = self.model()
        #expect(reopened.enabled)
        #expect(reopened.sensitivity == .moreHints)
        #expect(!reopened.switchLayoutAfterFix)
        #expect(!reopened.undoHintEnabled)
    }

    @Test("the typing speed is the app's one value")
    func typingSpeed() {
        box.settings.typingSpeedWordsPerMinute = 57
        #expect(model().typingSpeedWordsPerMinute == 57)
    }

    // MARK: - Apps

    @Test("caption: no apps, one app, several apps")
    func appsCaption() {
        #expect(TypingSettingsModel.appsCaption([]) == "Fixes work in every app.")
        #expect(TypingSettingsModel.appsCaption(["Xcode"]) == "Xcode")
        #expect(TypingSettingsModel.appsCaption(["Ghostty", "Xcode"]) == "Ghostty, Xcode")
    }

    @Test("a tick stores the bundle ID, in the order added; the caption shows names")
    func toggleApp() {
        let model = model()
        #expect(model.appsCaption == "Fixes work in every app.")

        model.toggleApp("com.apple.Safari")
        model.toggleApp("com.apple.dt.Xcode")
        #expect(box.settings.typingDisabledApps == ["com.apple.Safari", "com.apple.dt.Xcode"])
        #expect(model.appsCaption == "Safari, Xcode")

        model.toggleApp("com.apple.Safari")
        #expect(box.settings.typingDisabledApps == ["com.apple.dt.Xcode"])
        #expect(model.appsCaption == "Xcode")
    }

    @Test("the list is the running apps plus the chosen ones; a chosen app that is not running keeps its name")
    func appList() {
        box.settings.typingDisabledApps = ["com.mitchellh.ghostty", "com.example.gone", "com.apple.Safari"]
        let model = model()

        #expect(model.appIDs == ["com.apple.dt.Xcode", "com.apple.Safari", "com.mitchellh.ghostty", "com.example.gone"])
        #expect(model.appName("com.mitchellh.ghostty") == "Ghostty")
        #expect(model.appName("com.example.gone") == "com.example.gone")
        #expect(model.appsCaption == "Ghostty, com.example.gone, Safari")

        let rows = ChangeLanguagesRows(chosen: model.disabledApps, all: model.appIDs, query: "", name: model.appName)
        #expect(rows.chosen == ["com.mitchellh.ghostty", "com.example.gone", "com.apple.Safari"])
        #expect(rows.rest == ["com.apple.dt.Xcode"])
        let searched = ChangeLanguagesRows(chosen: model.disabledApps, all: model.appIDs, query: "xc", name: model.appName)
        #expect(searched.chosen.isEmpty)
        #expect(searched.rest == ["com.apple.dt.Xcode"])
    }
}
