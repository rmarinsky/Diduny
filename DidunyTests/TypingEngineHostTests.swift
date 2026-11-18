@testable import Diduny
import Foundation
import KeyboardShortcuts
import PapugaKit
import Testing

@MainActor
private final class FakeTypingEngine: TypingEngineControlling {
    var startSucceeds = true
    var isRunning = false
    var starts = 0
    var stops = 0
    var externalEdits = 0
    var undos = 0
    var historyApplied = 0

    func applyHistorySettings() { historyApplied += 1 }

    func start() -> Bool {
        starts += 1
        isRunning = startSucceeds
        return startSucceeds
    }

    func stop() {
        stops += 1
        isRunning = false
    }

    func noteExternalEdit() { externalEdits += 1 }
    func undoLastFix() { undos += 1 }
    func layoutConversion(of text: String) -> TypingLayoutConversion? { nil }
    func finishLayoutConversion(_: TypingLayoutConversion) {}
}

/// `reconcile()` is the only place that starts or stops the typing engine.
@MainActor
final class TypingEngineHostTests {
    private let box = IsolatedSettings("TypingEngineHostTests")
    private let engine = FakeTypingEngine()
    private var accessibilityGranted = true
    private var papugaRunning = false
    private var enginesBuilt = 0
    private let convertKeys = FakeKeySource()
    private lazy var sut = TypingEngineHost(
        settings: box.settings,
        isAccessibilityGranted: { [unowned self] in accessibilityGranted },
        isPapugaRunning: { [unowned self] in papugaRunning },
        makeEngine: { [unowned self] in
            enginesBuilt += 1
            return engine
        },
        convertMonitor: TypingConvertMonitor(source: convertKeys)
    )

    /// These tests start from "Fix as I type" off; a clean install now has it on.
    init() {
        box.settings.typingEnabled = false
    }

    @Test("Convert listens only while the engine runs and its switch is on, for the picked pair")
    func convertFollowsEngineAndSwitch() {
        box.settings.typingEnabled = true
        sut.reconcile()
        #expect(convertKeys.isActive)
        #expect(sut.activeConvertPair == .optionShift)

        box.settings.typingConvertPair = .controlShift
        sut.reconcile()
        #expect(sut.activeConvertPair == .controlShift)

        box.settings.typingConvertEnabled = false
        sut.reconcile()
        #expect(!convertKeys.isActive)
        #expect(sut.activeConvertPair == nil)

        box.settings.typingConvertEnabled = true
        box.settings.typingEnabled = false
        sut.reconcile()
        #expect(!convertKeys.isActive)
    }

    @Test("runs only with the setting on, Accessibility granted and a tap that starts", arguments: [
        (enabled: false, accessibility: false, startSucceeds: true, expected: TypingEngineHost.State.stopped),
        (enabled: false, accessibility: true, startSucceeds: true, expected: .stopped),
        (enabled: true, accessibility: false, startSucceeds: true, expected: .stopped),
        (enabled: true, accessibility: true, startSucceeds: false, expected: .startFailed),
        (enabled: true, accessibility: true, startSucceeds: true, expected: .running)
    ])
    func truthTable(enabled: Bool, accessibility: Bool, startSucceeds: Bool, expected: TypingEngineHost.State) {
        box.settings.typingEnabled = enabled
        accessibilityGranted = accessibility
        engine.startSucceeds = startSucceeds

        sut.reconcile()

        #expect(sut.state == expected)
        #expect(engine.isRunning == (expected == .running))
        // The engine is not even built until the setting and the permission allow it.
        #expect(enginesBuilt == (enabled && accessibility ? 1 : 0))
        #expect(engine.stops == 0)
    }

    @Test("a running Papuga keeps the engine off, whatever else is true", arguments: [
        (enabled: false, accessibility: true, expected: TypingEngineHost.State.stopped),
        (enabled: true, accessibility: false, expected: .stopped),
        (enabled: true, accessibility: true, expected: .papugaRunning)
    ])
    func truthTableWithPapuga(enabled: Bool, accessibility: Bool, expected: TypingEngineHost.State) {
        box.settings.typingEnabled = enabled
        accessibilityGranted = accessibility
        papugaRunning = true

        sut.reconcile()

        #expect(sut.state == expected)
        #expect(enginesBuilt == 0)
        #expect(engine.starts == 0)
    }

    @Test("Papuga launching stops the engine once, Papuga quitting starts it again")
    func papugaLaunchAndQuit() {
        box.settings.typingEnabled = true
        sut.reconcile()
        #expect(sut.state == .running)

        papugaRunning = true
        sut.reconcile()
        sut.reconcile()
        #expect(sut.state == .papugaRunning)
        #expect(!engine.isRunning)
        #expect(engine.stops == 1)

        papugaRunning = false
        sut.reconcile()
        #expect(sut.state == .running)
        #expect(engine.starts == 2)

        papugaRunning = true
        sut.reconcile()
        #expect(sut.state == .papugaRunning)
        #expect(engine.stops == 2)
        #expect(enginesBuilt == 1)
    }

    @Test("turning the setting off while Papuga runs ends as stopped; a pasted shortcut tells nobody")
    func papugaThenSettingOff() {
        box.settings.typingEnabled = true
        papugaRunning = true
        sut.reconcile()
        sut.noteExternalEdit()
        #expect(engine.externalEdits == 0)

        box.settings.typingEnabled = false
        sut.reconcile()
        #expect(sut.state == .stopped)
        #expect(engine.stops == 0)
    }

    @Test("a second reconcile neither starts a running engine again nor builds another")
    func reconcileTwiceWhileRunning() {
        box.settings.typingEnabled = true

        sut.reconcile()
        sut.reconcile()

        #expect(sut.state == .running)
        #expect(engine.starts == 1)
        #expect(enginesBuilt == 1)
    }

    @Test("a failed start is remembered and tried again on the next reconcile")
    func failedStartIsRetried() {
        box.settings.typingEnabled = true
        engine.startSucceeds = false

        sut.reconcile()
        #expect(sut.state == .startFailed)

        sut.reconcile()
        #expect(sut.state == .startFailed)
        #expect(engine.starts == 2)

        engine.startSucceeds = true
        sut.reconcile()
        #expect(sut.state == .running)
        #expect(engine.starts == 3)
        #expect(enginesBuilt == 1)
        #expect(engine.stops == 0)
    }

    @Test("turning the setting off stops the engine once")
    func settingOffStops() {
        box.settings.typingEnabled = true
        sut.reconcile()

        box.settings.typingEnabled = false
        sut.reconcile()
        sut.reconcile()

        #expect(sut.state == .stopped)
        #expect(engine.stops == 1)
    }

    @Test("losing Accessibility stops the engine, getting it back starts it")
    func accessibilityRevokedAndRestored() {
        box.settings.typingEnabled = true
        sut.reconcile()

        accessibilityGranted = false
        sut.reconcile()
        #expect(sut.state == .stopped)
        #expect(engine.stops == 1)

        accessibilityGranted = true
        sut.reconcile()
        #expect(sut.state == .running)
        #expect(engine.starts == 2)
    }

    @Test("a failed start that the setting then turns off ends as stopped, without a stop call")
    func failedThenOff() {
        box.settings.typingEnabled = true
        engine.startSucceeds = false
        sut.reconcile()

        box.settings.typingEnabled = false
        sut.reconcile()

        #expect(sut.state == .stopped)
        #expect(engine.stops == 0)
    }

    @Test("a shortcut posted by ClipboardService reaches the running engine")
    func clipboardShortcutTellsTheEngine() {
        let clipboard = ClipboardService()
        box.settings.typingEnabled = true
        sut.activate(clipboard: clipboard)
        #expect(sut.state == .running)

        clipboard.onShortcutPosted?()

        #expect(engine.externalEdits == 1)
    }

    @Test("a shortcut posted while the engine is stopped tells nobody")
    func clipboardShortcutWhileStopped() {
        let clipboard = ClipboardService()
        sut.activate(clipboard: clipboard)
        #expect(sut.state == .stopped)

        clipboard.onShortcutPosted?()

        #expect(engine.externalEdits == 0)
        #expect(enginesBuilt == 0)
    }

    @Test("the Undo shortcut reaches the engine only while it runs")
    func undoOnlyWhileRunning() {
        sut.undoLastFix()
        #expect(engine.undos == 0)
        #expect(enginesBuilt == 0)

        box.settings.typingEnabled = true
        sut.reconcile()
        sut.undoLastFix()
        #expect(engine.undos == 1)

        papugaRunning = true
        sut.reconcile()
        sut.undoLastFix()
        #expect(engine.undos == 1)
    }

    @Test("running changes are reported once each, so the Undo hotkey is registered only while the engine runs")
    func runningChangesAreReported() {
        var changes: [Bool] = []
        sut.onRunningChanged = { changes.append($0) }

        sut.reconcile()
        #expect(changes.isEmpty)

        box.settings.typingEnabled = true
        sut.reconcile()
        sut.reconcile()
        #expect(changes == [true])

        box.settings.typingEnabled = false
        sut.reconcile()
        sut.reconcile()
        #expect(changes == [true, false])
    }

    @Test("the engine's undo keys follow the Undo row: nil without keys or with the switch off")
    func undoShortcutFollowsTheRow() {
        #expect(box.settings.typingUndoShortcut == nil)

        KeyboardShortcuts.setShortcut(.init(.f19, modifiers: [.control, .option]), for: .undoLayoutFix)
        defer { KeyboardShortcuts.setShortcut(nil, for: .undoLayoutFix) }
        #expect(box.settings.typingUndoShortcut == AutoFixUndoShortcut(carbonKeyCode: 80, modifiers: [.control, .option]))

        box.settings.undoLayoutFixHotkeyEnabled = false
        #expect(box.settings.typingUndoShortcut == nil)
    }
}
