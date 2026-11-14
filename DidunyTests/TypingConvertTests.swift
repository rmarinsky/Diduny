import AppKit
@testable import Diduny
import Testing

/// Convert: the pair pressed twice, and push-to-talk never taking that gesture as its own (rule R1).
@MainActor
struct TypingConvertTests {
    private typealias Mask = PushToTalkService.DeviceModifierMask
    private static let option = NSEvent.ModifierFlags.option.rawValue
    private static let shift = NSEvent.ModifierFlags.shift.rawValue

    private let source = FakeKeySource()
    private let session = ShortcutCaptureSession(registrar: FakeHotkeyRegistrar(), notifications: NotificationCenter())

    /// Right Option then Right Shift down, both up.
    private func pairPress(_ send: (KeyEvent) -> Void, at t: TimeInterval) {
        send(.flags(KeyCode.rightOption, Self.option | Mask.rightOption, at: t))
        send(.flags(KeyCode.rightShift, Self.option | Self.shift | Mask.rightOption | Mask.rightShift, at: t + 0.02))
        send(.flags(KeyCode.rightOption, Self.shift | Mask.rightShift, at: t + 0.06))
        send(.flags(KeyCode.rightShift, 0, at: t + 0.07))
    }

    private func makeMonitor() -> (TypingConvertMonitor, () -> Int) {
        let monitor = TypingConvertMonitor(source: source, captureSession: session)
        var fired = 0
        monitor.onTrigger = { fired += 1 }
        monitor.listen(for: .optionShift)
        return (monitor, { fired })
    }

    @Test("The pair pressed twice inside 0.4 s fires once")
    func pairTwiceFires() {
        let (monitor, fired) = makeMonitor()
        defer { withExtendedLifetime(monitor) {} }
        pairPress(source.send, at: 1.0)
        #expect(fired() == 0)
        pairPress(source.send, at: 1.2)
        #expect(fired() == 1)
    }

    @Test("Once, or twice too slowly, fires nothing")
    func onceOrSlowFiresNothing() {
        let (monitor, fired) = makeMonitor()
        defer { withExtendedLifetime(monitor) {} }
        pairPress(source.send, at: 1.0)
        pairPress(source.send, at: 1.5)
        #expect(fired() == 0)
    }

    @Test("A key typed between the presses starts over")
    func keyDownResets() {
        let (monitor, fired) = makeMonitor()
        defer { withExtendedLifetime(monitor) {} }
        pairPress(source.send, at: 1.0)
        source.send(.keyDown(keyCode: KeyCode.a, modifiersRawValue: 0, isRepeat: false, timestamp: 1.1))
        pairPress(source.send, at: 1.2)
        #expect(fired() == 0)
    }

    @Test("Nothing fires while a shortcut is being recorded")
    func captureSessionBlocks() {
        let (monitor, fired) = makeMonitor()
        defer { withExtendedLifetime(monitor) {} }
        session.begin()
        pairPress(source.send, at: 1.0)
        pairPress(source.send, at: 1.2)
        session.end()
        #expect(fired() == 0)
    }

    @Test("listen(for: nil) stops the key source")
    func listenNilStops() {
        let (monitor, _) = makeMonitor()
        #expect(source.isActive)
        monitor.listen(for: nil)
        #expect(!source.isActive)
    }

    // MARK: - R1

    private func makePushToTalk(convertOn: Bool, hold: Bool, toggle: Bool) -> (PushToTalkService, ManualScheduler) {
        let scheduler = ManualScheduler()
        let ptt = PushToTalkService(source: source, scheduler: scheduler, captureSession: session)
        ptt.selectedKey = .rightOption
        ptt.holdModeEnabled = hold
        ptt.toggleModeEnabled = toggle
        ptt.toggleTapCount = 2
        ptt.holdStartDelaySeconds = 0.5
        ptt.convertPair = { convertOn ? TypingConvertPair.optionShift.families : nil }
        ptt.start()
        scheduler.advance(by: 0.5)
        return (ptt, scheduler)
    }

    @Test("With Convert on, the pair twice on push-to-talk's key toggles nothing and starts no hold")
    func convertOnBlocksPushToTalk() {
        let (ptt, scheduler) = makePushToTalk(convertOn: true, hold: true, toggle: true)
        var toggles = 0, starts = 0
        ptt.onToggle = { toggles += 1 }
        ptt.onKeyDown = { starts += 1 }
        pairPress(source.send, at: 1.0)
        pairPress(source.send, at: 1.2)
        // Shift first, then Option, held past the hold delay.
        source.send(.flags(KeyCode.rightShift, Self.shift | Mask.rightShift, at: 2.0))
        source.send(.flags(KeyCode.rightOption, Self.option | Self.shift | Mask.rightOption | Mask.rightShift, at: 2.02))
        scheduler.advance(by: 1.0)
        #expect(toggles == 0)
        #expect(starts == 0)
    }

    @Test("With Convert off, the same presses toggle as before")
    func convertOffKeepsPushToTalk() {
        let (ptt, _) = makePushToTalk(convertOn: false, hold: false, toggle: true)
        var toggles = 0
        ptt.onToggle = { toggles += 1 }
        pairPress(source.send, at: 1.0)
        pairPress(source.send, at: 1.2)
        #expect(toggles == 1)
    }

    @Test("With Convert on, a lone tap of push-to-talk's key still counts")
    func loneTapsStillToggle() {
        let (ptt, _) = makePushToTalk(convertOn: true, hold: false, toggle: true)
        var toggles = 0
        ptt.onToggle = { toggles += 1 }
        for t in [1.0, 1.1] {
            source.send(.flags(KeyCode.rightOption, Self.option | Mask.rightOption, at: t))
            source.send(.flags(KeyCode.rightOption, 0, at: t + 0.03))
        }
        #expect(toggles == 1)
    }
}
