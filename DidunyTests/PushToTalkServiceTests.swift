import AppKit
@testable import Diduny
import Testing

/// Push-to-talk on a fake key source and a manual scheduler: no real sleeps (test-plan T5-PT-*).
@Suite("PushToTalkService Hold Delay")
@MainActor
final class PushToTalkServiceTests {
    private typealias Mask = PushToTalkService.DeviceModifierMask

    private let box = IsolatedSettings("PushToTalkServiceTests")
    private let source = FakeKeySource()
    private let scheduler = ManualScheduler()
    private let session = ShortcutCaptureSession(registrar: FakeHotkeyRegistrar(), notifications: NotificationCenter())

    private func makeService(
        key: PushToTalkKey = .rightShift,
        hold: Bool = true,
        toggle: Bool = false,
        tapCount: Int = 2,
        delay: TimeInterval = 0.5,
        source: FakeKeySource? = nil
    ) -> PushToTalkService {
        let sut = PushToTalkService(source: source ?? self.source, scheduler: scheduler, captureSession: session)
        sut.selectedKey = key
        sut.holdModeEnabled = hold
        sut.toggleModeEnabled = toggle
        sut.toggleTapCount = tapCount
        sut.holdStartDelaySeconds = delay
        return sut
    }

    /// `start()` and wait out the 0.5 s cooldown.
    private func startReady(_ sut: PushToTalkService) {
        sut.start()
        scheduler.advance(by: 0.5)
    }

    private func rightShift(down: Bool, at t: TimeInterval) -> KeyEvent {
        .flags(KeyCode.rightShift, down ? NSEvent.ModifierFlags.shift.rawValue | Mask.rightShift : 0, at: t)
    }

    private func tap(_ sut: PushToTalkService, at t: TimeInterval) {
        source.send(rightShift(down: true, at: t))
        source.send(rightShift(down: false, at: t + 0.05))
    }

    // MARK: - Ported cases (kept)

    @Test("Short hold before threshold does not start or stop recording")
    func shortHoldBeforeThresholdDoesNotStart() {
        let sut = makeService()
        var starts = 0
        var stops = 0
        sut.onKeyDown = { starts += 1 }
        sut.onKeyUp = { stops += 1 }

        sut.processModifierKeyEvent(isPressed: true, eventTime: 0)
        scheduler.advance(by: 0.2)
        sut.processModifierKeyEvent(isPressed: false, eventTime: 0.2)
        scheduler.advance(by: 0.35)

        #expect(starts == 0)
        #expect(stops == 0)
    }

    @Test("Hold past threshold starts once and release stops once")
    func holdPastThresholdStartsAndReleaseStops() {
        let sut = makeService()
        var starts = 0
        var stops = 0
        sut.onKeyDown = { starts += 1 }
        sut.onKeyUp = { stops += 1 }

        sut.processModifierKeyEvent(isPressed: true, eventTime: 0)
        scheduler.advance(by: 0.55)
        #expect(starts == 1)
        #expect(stops == 0)

        sut.processModifierKeyEvent(isPressed: false, eventTime: 0.55)
        scheduler.advance(by: 0.05)
        #expect(starts == 1)
        #expect(stops == 1)
    }

    @Test("Reset while hold is active preserves release stop")
    func resetHandsFreeModeDuringActiveHoldPreservesReleaseStop() {
        let sut = makeService()
        var starts = 0
        var stops = 0
        sut.onKeyDown = { starts += 1 }
        sut.onKeyUp = { stops += 1 }

        sut.processModifierKeyEvent(isPressed: true, eventTime: 0)
        scheduler.advance(by: 0.55)
        sut.resetHandsFreeMode()
        sut.processModifierKeyEvent(isPressed: false, eventTime: 0.6)

        #expect(starts == 1)
        #expect(stops == 1)
    }

    @Test("Hands-free toggle ignores hold delay")
    func handsFreeToggleIgnoresHoldDelay() {
        let sut = makeService(hold: false, toggle: true, tapCount: 2, delay: 1.0)
        var toggles = 0
        var starts = 0
        sut.onToggle = { toggles += 1 }
        sut.onKeyDown = { starts += 1 }

        sut.processModifierKeyEvent(isPressed: true, eventTime: 0)
        sut.processModifierKeyEvent(isPressed: false, eventTime: 0.05)
        sut.processModifierKeyEvent(isPressed: true, eventTime: 0.1)
        scheduler.advance(by: 2)

        #expect(toggles == 1)
        #expect(starts == 0)
    }

    @Test("T5-PT-13 hold and toggle modes can be enabled together")
    func holdAndToggleModesCanBeEnabledTogether() {
        let sut = makeService(hold: true, toggle: true, tapCount: 2, delay: 0.5)
        var starts = 0
        var stops = 0
        var toggles = 0
        sut.onKeyDown = { starts += 1 }
        sut.onKeyUp = { stops += 1 }
        sut.onToggle = { toggles += 1 }

        sut.processModifierKeyEvent(isPressed: true, eventTime: 0)
        sut.processModifierKeyEvent(isPressed: false, eventTime: 0.05)
        sut.processModifierKeyEvent(isPressed: true, eventTime: 0.1)
        sut.processModifierKeyEvent(isPressed: false, eventTime: 0.15)
        scheduler.advance(by: 0.15)
        #expect(toggles == 1)
        #expect(starts == 0)
        #expect(stops == 0)

        // A hold while hands-free does not start a second recording.
        sut.processModifierKeyEvent(isPressed: true, eventTime: 0.5)
        scheduler.advance(by: 0.6)
        sut.processModifierKeyEvent(isPressed: false, eventTime: 0.9)
        #expect(starts == 0)

        sut.processModifierKeyEvent(isPressed: true, eventTime: 1.0)
        sut.processModifierKeyEvent(isPressed: false, eventTime: 1.05)
        sut.processModifierKeyEvent(isPressed: true, eventTime: 1.1)
        sut.processModifierKeyEvent(isPressed: false, eventTime: 1.15)
        scheduler.advance(by: 0.15)
        #expect(toggles == 2)
        #expect(starts == 0)

        sut.processModifierKeyEvent(isPressed: true, eventTime: 2.0)
        scheduler.advance(by: 0.55)
        sut.processModifierKeyEvent(isPressed: false, eventTime: 2.6)
        #expect(starts == 1)
        #expect(stops == 1)
    }

    @Test("Settings clamp hold start delay range")
    func settingsClampHoldStartDelayRange() {
        let settings = box.settings
        settings.pushToTalkHoldStartDelaySeconds = 0.05
        #expect(settings.pushToTalkHoldStartDelaySeconds == 0.5)

        settings.pushToTalkHoldStartDelaySeconds = 2.5
        #expect(settings.pushToTalkHoldStartDelaySeconds == 2.0)

        settings.translationPushToTalkHoldStartDelaySeconds = 0.55
        #expect(settings.translationPushToTalkHoldStartDelaySeconds == 0.6)
    }

    // MARK: - Events from the key source

    @Test("T5-PT-01 events in the first 0.5 s after start are ignored")
    func cooldownIgnoresEarlyEvents() {
        let sut = makeService(hold: false, toggle: true)
        var toggles = 0
        sut.onToggle = { toggles += 1 }

        sut.start()
        tap(sut, at: 0.1)
        tap(sut, at: 0.2)
        scheduler.advance(to: 0.49)
        tap(sut, at: 0.3)
        tap(sut, at: 0.4)
        #expect(toggles == 0)

        scheduler.advance(to: 0.5)
        tap(sut, at: 0.6)
        tap(sut, at: 0.7)
        #expect(toggles == 1)
    }

    @Test("T5-PT-02 other keys are ignored")
    func otherKeysIgnored() {
        let sut = makeService(hold: false, toggle: true)
        var toggles = 0
        sut.onToggle = { toggles += 1 }
        startReady(sut)

        for t in [1.0, 1.1, 1.2] {
            source.send(.flags(KeyCode.leftShift, NSEvent.ModifierFlags.shift.rawValue | Mask.leftShift, at: t))
            source.send(.flags(KeyCode.leftShift, 0, at: t + 0.05))
        }
        #expect(toggles == 0)
    }

    @Test("T5-PT-03 the side mask decides key up while the other side is held")
    func sideMaskDecidesKeyUp() {
        let sut = makeService(hold: true, delay: 0.5)
        var starts = 0
        var stops = 0
        sut.onKeyDown = { starts += 1 }
        sut.onKeyUp = { stops += 1 }
        startReady(sut)

        let shift = NSEvent.ModifierFlags.shift.rawValue
        source.send(.flags(KeyCode.leftShift, shift | Mask.leftShift, at: 1.0))
        source.send(.flags(KeyCode.rightShift, shift | Mask.leftShift | Mask.rightShift, at: 1.1))
        scheduler.advance(by: 0.5)
        #expect(starts == 1)

        source.send(.flags(KeyCode.rightShift, shift | Mask.leftShift, at: 1.7))
        #expect(stops == 1)
    }

    @Test("T5-PT-04 double tap starts, double tap stops")
    func doubleTapStartsAndStops() {
        let sut = makeService(hold: false, toggle: true)
        var toggles = 0
        sut.onToggle = { toggles += 1 }
        startReady(sut)

        tap(sut, at: 1.0)
        tap(sut, at: 1.1)
        #expect(toggles == 1)
        #expect(sut.isHandsFreeMode)

        tap(sut, at: 3.0)
        tap(sut, at: 3.1)
        #expect(toggles == 2)
        #expect(!sut.isHandsFreeMode)
    }

    @Test("T5-PT-05 the tap window is 0.3 s, strict")
    func tapWindowBoundary() {
        let first = makeService(hold: false, toggle: true)
        var firstToggles = 0
        first.onToggle = { firstToggles += 1 }
        first.processModifierKeyEvent(isPressed: true, eventTime: 1.0)
        first.processModifierKeyEvent(isPressed: false, eventTime: 1.05)
        first.processModifierKeyEvent(isPressed: true, eventTime: 1.299)
        #expect(firstToggles == 1)

        let second = makeService(hold: false, toggle: true)
        var secondToggles = 0
        second.onToggle = { secondToggles += 1 }
        second.processModifierKeyEvent(isPressed: true, eventTime: 1.0)
        second.processModifierKeyEvent(isPressed: false, eventTime: 1.05)
        second.processModifierKeyEvent(isPressed: true, eventTime: 1.300)
        #expect(secondToggles == 0)
    }

    @Test("T5-PT-06 triple tap")
    func tripleTap() {
        let sut = makeService(hold: false, toggle: true, tapCount: 3)
        var toggles = 0
        sut.onToggle = { toggles += 1 }
        startReady(sut)

        tap(sut, at: 1.0)
        tap(sut, at: 1.1)
        #expect(toggles == 0)

        tap(sut, at: 3.0)
        tap(sut, at: 3.1)
        tap(sut, at: 3.2)
        #expect(toggles == 1)
    }

    @Test("T5-PT-07 tap off: quick taps never toggle")
    func tapOff() {
        let sut = makeService(hold: true, toggle: false)
        var toggles = 0
        sut.onToggle = { toggles += 1 }
        startReady(sut)

        for i in 0 ..< 6 {
            tap(sut, at: 1.0 + Double(i) * 0.1)
        }
        #expect(toggles == 0)
    }

    @Test("T5-PT-08 tap count clamps: 1 acts as 2, 5 acts as 3")
    func tapCountClamps() {
        let low = makeService(hold: false, toggle: true, tapCount: 1)
        var lowToggles = 0
        low.onToggle = { lowToggles += 1 }
        low.processModifierKeyEvent(isPressed: true, eventTime: 1.0)
        low.processModifierKeyEvent(isPressed: false, eventTime: 1.05)
        #expect(lowToggles == 0)
        low.processModifierKeyEvent(isPressed: true, eventTime: 1.1)
        #expect(lowToggles == 1)

        let high = makeService(hold: false, toggle: true, tapCount: 5)
        var highToggles = 0
        high.onToggle = { highToggles += 1 }
        for (i, t) in [1.0, 1.1, 1.2].enumerated() {
            high.processModifierKeyEvent(isPressed: true, eventTime: t)
            high.processModifierKeyEvent(isPressed: false, eventTime: t + 0.05)
            #expect(highToggles == (i == 2 ? 1 : 0))
        }
    }

    @Test("T5-PT-09 hold starts at the delay and stops on release")
    func holdStartsAtDelay() {
        let sut = makeService(hold: true, delay: 1.2)
        var starts = 0
        var stops = 0
        sut.onKeyDown = { starts += 1 }
        sut.onKeyUp = { stops += 1 }
        startReady(sut)

        source.send(rightShift(down: true, at: 1.0))
        scheduler.advance(by: 1.19)
        #expect(starts == 0)
        scheduler.advance(by: 0.01)
        #expect(starts == 1)
        source.send(rightShift(down: false, at: 2.5))
        #expect(stops == 1)
    }

    @Test("T5-PT-10 release before the delay cancels")
    func releaseBeforeDelayCancels() {
        let sut = makeService(hold: true, delay: 1.2)
        var starts = 0
        var stops = 0
        sut.onKeyDown = { starts += 1 }
        sut.onKeyUp = { stops += 1 }
        startReady(sut)

        source.send(rightShift(down: true, at: 1.0))
        scheduler.advance(by: 0.5)
        source.send(rightShift(down: false, at: 1.5))
        scheduler.advance(by: 2)
        #expect(starts == 0)
        #expect(stops == 0)
    }

    @Test("T5-PT-11 hold delay values start at their delay", arguments: [0.5, 1.2, 2.0])
    func holdDelayValues(delay: TimeInterval) {
        let sut = makeService(hold: true, delay: delay)
        var starts = 0
        sut.onKeyDown = { starts += 1 }
        sut.processModifierKeyEvent(isPressed: true, eventTime: 0)
        scheduler.advance(by: delay - 0.01)
        #expect(starts == 0)
        scheduler.advance(by: 0.01)
        #expect(starts == 1)
    }

    @Test("T5-PT-11 hold delay clamping")
    func holdDelayClamping() {
        let sut = makeService()
        let settings = box.settings
        for (input, expected) in [(0.4, 0.5), (2.5, 2.0), (1.23, 1.2), (Double.nan, 1.2)] {
            sut.holdStartDelaySeconds = input
            #expect(sut.holdStartDelaySeconds == expected, "service \(input)")
            settings.pushToTalkHoldStartDelaySeconds = input
            #expect(settings.pushToTalkHoldStartDelaySeconds == expected, "settings \(input)")
        }
    }

    @Test("T5-PT-12 hold off and tap off never start and do not monitor")
    func holdOffNeverStarts() {
        let sut = makeService(hold: false, toggle: false)
        var starts = 0
        sut.onKeyDown = { starts += 1 }
        sut.start()
        #expect(!source.isActive)

        source.send(rightShift(down: true, at: 1.0))
        scheduler.advance(by: 5)
        #expect(starts == 0)
    }

    @Test("T5-PT-14 Caps Lock alternates down and up")
    func capsLockAlternates() {
        let sut = makeService(key: .capsLock, hold: true, delay: 0.5)
        var starts = 0
        var stops = 0
        sut.onKeyDown = { starts += 1 }
        sut.onKeyUp = { stops += 1 }
        startReady(sut)

        let caps = NSEvent.ModifierFlags.capsLock.rawValue
        source.send(.flags(KeyCode.capsLock, caps, at: 1.0))
        scheduler.advance(by: 0.5)
        source.send(.flags(KeyCode.capsLock, 0, at: 2.0))
        #expect((starts, stops) == (1, 1))

        source.send(.flags(KeyCode.capsLock, caps, at: 3.0))
        scheduler.advance(by: 0.5)
        source.send(.flags(KeyCode.capsLock, 0, at: 4.0))
        #expect((starts, stops) == (2, 2))
    }

    @Test("T5-PT-15 a disabled key does not monitor")
    func disabledKeyDoesNotMonitor() {
        let sut = makeService(key: .none, hold: true, toggle: true)
        sut.start()
        #expect(!source.isActive)
        #expect(scheduler.pendingCount == 0)
    }

    @Test("Stop removes the subscription and the pending cooldown")
    func stopRemovesSubscription() {
        let sut = makeService()
        sut.start()
        #expect(source.isActive)
        sut.stop()
        #expect(!source.isActive)
        #expect(scheduler.pendingCount == 0)
    }

    @Test("T5-PT-16 reset after an external cancel: the next toggle starts")
    func resetAfterExternalCancel() {
        let sut = makeService(hold: false, toggle: true)
        startReady(sut)
        tap(sut, at: 1.0)
        tap(sut, at: 1.1)
        #expect(sut.isHandsFreeMode)

        sut.resetHandsFreeMode()
        #expect(!sut.isHandsFreeMode)
        tap(sut, at: 3.0)
        tap(sut, at: 3.1)
        #expect(sut.isHandsFreeMode, "The toggle reports a start, not a stop")
    }

    @Test("T5-PT-17 settings are applied to the running service")
    func configuratorAppliesSettings() {
        let settings = box.settings
        settings.pushToTalkKey = .leftOption
        settings.pushToTalkHoldEnabled = true
        settings.pushToTalkToggleEnabled = true
        settings.pushToTalkToggleTapCount = 3
        settings.pushToTalkHoldStartDelaySeconds = 1.7

        let sut = makeService(key: .none, hold: false, toggle: false)
        let config = PushToTalkConfigurator.dictation(settings)
        PushToTalkConfigurator.apply(config, to: sut)

        #expect(sut.selectedKey == .leftOption)
        #expect(sut.holdModeEnabled)
        #expect(sut.toggleModeEnabled)
        #expect(sut.toggleTapCount == 3)
        #expect(sut.holdStartDelaySeconds == 1.7)
        #expect(source.isActive)

        settings.pushToTalkHoldEnabled = false
        settings.pushToTalkToggleEnabled = false
        PushToTalkConfigurator.apply(PushToTalkConfigurator.dictation(settings), to: sut)
        #expect(!source.isActive, "Monitoring is off when hold and tap are both off")

        settings.translationPushToTalkKey = .rightCommand
        settings.translationPushToTalkHoldEnabled = true
        settings.translationPushToTalkToggleEnabled = false
        settings.translationPushToTalkHoldStartDelaySeconds = 0.8
        let translation = PushToTalkConfigurator.translation(settings)
        #expect(translation == PushToTalkConfigurator.Config(
            key: .rightCommand, hold: true, toggle: false,
            tapCount: settings.translationPushToTalkToggleTapCount, holdDelay: 0.8
        ))
    }

    @Test("T5-PT-18 dictation and translation services are independent")
    func servicesAreIndependent() {
        let translationSource = FakeKeySource()
        let dictation = makeService(key: .rightShift, hold: false, toggle: true)
        let translation = makeService(key: .rightOption, hold: false, toggle: true, source: translationSource)
        var dictationToggles = 0
        var translationToggles = 0
        dictation.onToggle = { dictationToggles += 1 }
        translation.onToggle = { translationToggles += 1 }
        dictation.start()
        translation.start()
        scheduler.advance(by: 0.5)

        let option = NSEvent.ModifierFlags.option.rawValue
        for t in [1.0, 1.1] {
            for target in [source, translationSource] {
                target.send(.flags(KeyCode.rightOption, option | Mask.rightOption, at: t))
                target.send(.flags(KeyCode.rightOption, 0, at: t + 0.05))
            }
        }
        #expect(translationToggles == 1)
        #expect(dictationToggles == 0)
    }

    @Test("Taps are ignored while a shortcut with the push-to-talk key is being recorded")
    func ignoredDuringCapture() {
        let sut = makeService(hold: true, toggle: true, delay: 0.5)
        var toggles = 0
        var starts = 0
        sut.onToggle = { toggles += 1 }
        sut.onKeyDown = { starts += 1 }
        startReady(sut)

        session.begin()
        tap(sut, at: 1.0)
        tap(sut, at: 1.1)
        source.send(rightShift(down: true, at: 1.5))
        scheduler.advance(by: 1)
        #expect(toggles == 0)
        #expect(starts == 0)

        session.end()
        source.send(rightShift(down: false, at: 2.6))
        tap(sut, at: 3.0)
        tap(sut, at: 3.1)
        #expect(toggles == 1)
    }

    @Test("T5-PT-19 reserved keys follow push-to-talk")
    func reservedKeysFollowPushToTalk() {
        let settings = box.settings
        settings.pushToTalkKey = .leftOption
        settings.pushToTalkHoldEnabled = true
        settings.translationPushToTalkKey = .rightOption
        settings.translationPushToTalkHoldEnabled = true

        #expect(settings.inplaceTranslationReservedKeys == [.leftOption, .rightOption])
        #expect(!settings.inplaceTranslationActive)
    }
}
