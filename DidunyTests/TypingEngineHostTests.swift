@testable import Diduny
import Foundation
import Testing

@MainActor
private final class FakeTypingEngine: TypingEngineControlling {
    var startSucceeds = true
    var isRunning = false
    var starts = 0
    var stops = 0
    var externalEdits = 0

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
}

/// `reconcile()` is the only place that starts or stops the typing engine.
@MainActor
final class TypingEngineHostTests {
    private let box = IsolatedSettings("TypingEngineHostTests")
    private let engine = FakeTypingEngine()
    private var accessibilityGranted = true
    private var enginesBuilt = 0
    private lazy var sut = TypingEngineHost(
        settings: box.settings,
        isAccessibilityGranted: { [unowned self] in accessibilityGranted },
        makeEngine: { [unowned self] in
            enginesBuilt += 1
            return engine
        }
    )

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
}
