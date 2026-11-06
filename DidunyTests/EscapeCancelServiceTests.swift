import AppKit
import Testing

@testable import Diduny

/// Cancel recording: stored key, 1x 2x 3x, switch (test-plan T5-CA-*). Every case runs on its own
/// settings suite, a fake key source and a manual scheduler, so nothing sleeps or touches `.shared`.
@Suite("EscapeCancelService Press Logic")
@MainActor
final class EscapeCancelServiceTests {
    private let box = IsolatedSettings("EscapeCancelServiceTests")
    private let source = FakeKeySource()
    private let scheduler = ManualScheduler()
    private let session = ShortcutCaptureSession(registrar: FakeHotkeyRegistrar())
    private lazy var sut = EscapeCancelService(
        settings: box.settings,
        source: source,
        clock: scheduler,
        scheduler: scheduler,
        captureSession: session,
        playsSound: false
    )

    private var settings: SettingsStorage { box.settings }

    init() {
        box.settings.escapeCancelEnabled = true
        box.settings.escapeCancelPressCount = 2
    }

    private let controlX = RecordingCancelShortcut(
        keyCode: KeyCode.x,
        modifiersRawValue: NSEvent.ModifierFlags.control.rawValue,
        keyLabel: "X"
    )

    // MARK: - T5-CA-01 existing press logic, kept

    @Test("Two presses within threshold triggers cancel")
    func doublePressTriggersCancel() {
        var cancelled = false
        sut.onCancel = { cancelled = true }

        let t0: TimeInterval = 100
        sut.processEscapePress(at: t0)
        #expect(!cancelled)

        sut.processEscapePress(at: t0 + 0.3)
        #expect(cancelled)
    }

    @Test("Two presses outside threshold does not cancel")
    func pressesOutsideThresholdDoNotCancel() {
        var cancelled = false
        sut.onCancel = { cancelled = true }

        let t0: TimeInterval = 100
        sut.processEscapePress(at: t0)
        sut.processEscapePress(at: t0 + 2.0)

        #expect(!cancelled)
    }

    @Test("Three presses required when configured for 3")
    func triplePressCancel() {
        settings.escapeCancelPressCount = 3

        var cancelled = false
        sut.onCancel = { cancelled = true }

        let t0: TimeInterval = 100
        sut.processEscapePress(at: t0)
        #expect(!cancelled)

        sut.processEscapePress(at: t0 + 0.3)
        #expect(!cancelled)

        sut.processEscapePress(at: t0 + 0.6)
        #expect(cancelled)
    }

    @Test("onProgressEscape fires with correct counts")
    func progressCallbackCounts() {
        settings.escapeCancelPressCount = 3

        var progressCalls: [(current: Int, required: Int)] = []
        sut.onProgressEscape = { current, required in
            progressCalls.append((current, required))
        }

        let t0: TimeInterval = 100
        sut.processEscapePress(at: t0)
        sut.processEscapePress(at: t0 + 0.3)

        #expect(progressCalls.count == 2)
        #expect(progressCalls[0].current == 1)
        #expect(progressCalls[0].required == 3)
        #expect(progressCalls[1].current == 2)
        #expect(progressCalls[1].required == 3)
    }

    @Test("onProgressEscape does not fire on final press (onCancel fires instead)")
    func progressDoesNotFireOnFinalPress() {
        var progressCount = 0
        var cancelled = false
        sut.onProgressEscape = { _, _ in progressCount += 1 }
        sut.onCancel = { cancelled = true }

        let t0: TimeInterval = 100
        sut.processEscapePress(at: t0)
        sut.processEscapePress(at: t0 + 0.3)

        #expect(progressCount == 1)
        #expect(cancelled)
    }

    @Test("Press at exactly 1.5s still counts (<=)")
    func thresholdBoundaryInclusive() {
        var cancelled = false
        sut.onCancel = { cancelled = true }

        sut.processEscapePress(at: 0)
        sut.processEscapePress(at: 1.5)

        #expect(cancelled)
    }

    @Test("Press at 1.501s resets count")
    func thresholdBoundaryExclusive() {
        var cancelled = false
        sut.onCancel = { cancelled = true }

        sut.processEscapePress(at: 0)
        sut.processEscapePress(at: 1.501)

        #expect(!cancelled)
    }

    @Test("Count resets when gap exceeds threshold")
    func countResetsAfterGap() {
        settings.escapeCancelPressCount = 3
        var cancelled = false
        sut.onCancel = { cancelled = true }

        let t0: TimeInterval = 100
        sut.processEscapePress(at: t0)
        sut.processEscapePress(at: t0 + 0.5)
        sut.processEscapePress(at: t0 + 3.0)

        #expect(!cancelled, "Count should have reset after gap, so 3rd press starts over at 1")
    }

    // MARK: - Keys from the key source

    @Test("An existing user's Esc keeps cancelling: nothing stored reads as Esc")
    func unsetShortcutIsEsc() {
        var cancels = 0
        sut.onCancel = { cancels += 1 }
        sut.activate()

        source.send(.key(KeyCode.escape))
        source.send(.key(KeyCode.escape, [.shift]))
        #expect(cancels == 1, "A bare stored key matches with any modifiers, as the key-code-53 check did")
        #expect(box.defaults.object(forKey: "escapeCancelShortcut") == nil)
    }

    @Test("T5-CA-02 1x cancels on the first press")
    func singlePressCancels() {
        settings.escapeCancelPressCount = 1
        var cancels = 0
        var progress = 0
        sut.onCancel = { cancels += 1 }
        sut.onProgressEscape = { _, _ in progress += 1 }
        sut.activate()

        source.send(.key(KeyCode.escape))
        #expect(cancels == 1)
        #expect(progress == 0)
    }

    @Test("T5-CA-03 any key: only the stored chord's key-downs count")
    func anyStoredKey() {
        settings.escapeCancelShortcut = controlX
        var cancels = 0
        sut.onCancel = { cancels += 1 }
        sut.activate()

        source.send(.key(KeyCode.escape))
        source.send(.key(KeyCode.x))
        source.send(.key(KeyCode.x, [.control], isRepeat: true))
        source.send(.key(KeyCode.x, [.control]))
        #expect(cancels == 0)
        source.send(.key(KeyCode.x, [.control]))
        #expect(cancels == 1)
    }

    @Test("Esc no longer cancels when another key is stored")
    func escDoesNotCancelWhenAnotherKeyIsStored() {
        settings.escapeCancelShortcut = RecordingCancelShortcut(
            keyCode: KeyCode.a,
            modifiersRawValue: NSEvent.ModifierFlags.command.rawValue,
            keyLabel: "A"
        )
        settings.escapeCancelPressCount = 1
        var cancels = 0
        sut.onCancel = { cancels += 1 }
        sut.activate()

        source.send(.key(KeyCode.escape))
        #expect(cancels == 0)
        source.send(.key(KeyCode.a, [.command]))
        #expect(cancels == 1)
    }

    @Test("T5-CA-04 switch off: nothing cancels and the count is reset")
    func switchOff() {
        settings.escapeCancelEnabled = false
        var cancels = 0
        sut.onCancel = { cancels += 1 }
        sut.activate()

        source.send(.key(KeyCode.escape))
        source.send(.key(KeyCode.escape))
        #expect(cancels == 0)

        settings.escapeCancelEnabled = true
        source.send(.key(KeyCode.escape))
        #expect(cancels == 0, "Presses made while off do not count")
    }

    @Test("T5-CA-05 the timeout resets without a real sleep")
    func timeoutResets() {
        settings.escapeCancelPressCount = 3
        var cancels = 0
        sut.onCancel = { cancels += 1 }
        sut.activate()

        source.send(.key(KeyCode.escape))
        #expect(scheduler.pendingCount == 1)
        scheduler.advance(by: 1.6)
        #expect(scheduler.pendingCount == 0)
        source.send(.key(KeyCode.escape))
        source.send(.key(KeyCode.escape))
        #expect(cancels == 0)
    }

    @Test("T5-CA-06 the repeat hint names the stored key")
    func repeatHintNamesStoredKey() {
        settings.escapeCancelShortcut = controlX
        settings.escapeCancelPressCount = 3
        let hint = settings.escapeCancelRepeatHint(afterPressCount: 1)
        #expect(hint.contains("⌃X"))
        #expect(!hint.contains("Esc"))
    }

    @Test("The repeat hint for an unset key still says Esc")
    func repeatHintDefaultsToEsc() {
        #expect(settings.escapeCancelRepeatHint(afterPressCount: 1).contains("Esc"))
    }

    @Test("T5-CA-08 only while recording")
    func onlyWhileActivated() {
        var cancels = 0
        sut.onCancel = { cancels += 1 }
        source.send(.key(KeyCode.escape))
        source.send(.key(KeyCode.escape))
        #expect(cancels == 0)
        #expect(!source.isActive)

        sut.activate()
        #expect(source.isActive)
        sut.deactivate()
        #expect(!source.isActive)
    }

    @Test("T5-CA-09 count range: 0 and 4 fall back to 2; 1, 2 and 3 are kept")
    func countRange() {
        box.defaults.set(0, forKey: "escapeCancelPressCount")
        #expect(settings.escapeCancelPressCount == 2)
        box.defaults.set(4, forKey: "escapeCancelPressCount")
        #expect(settings.escapeCancelPressCount == 2)
        for count in 1 ... 3 {
            settings.escapeCancelPressCount = count
            #expect(settings.escapeCancelPressCount == count)
        }
    }

    @Test("Keys are ignored while a shortcut is being captured")
    func ignoredDuringCapture() {
        settings.escapeCancelPressCount = 1
        var cancels = 0
        sut.onCancel = { cancels += 1 }
        sut.activate()

        session.begin()
        source.send(.key(KeyCode.escape))
        #expect(cancels == 0)
        session.end()
        source.send(.key(KeyCode.escape))
        #expect(cancels == 1)
    }
}
