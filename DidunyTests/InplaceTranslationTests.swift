@testable import Diduny
import AppKit
import KeyboardShortcuts
import Testing

struct InplaceTranslationGestureTests {
    private typealias Gesture = InplaceTranslationGesture
    private let both: Gesture.Modifiers = [.option, .command]

    /// Feeds a full tap (⌥ down, ⌘ down, ⌘ up, ⌥ up) starting at `t`; returns whether it completed the gesture.
    private func tap(_ g: inout Gesture, at t: TimeInterval, hold: TimeInterval = 0.08) -> Bool {
        _ = g.handle(.modifiersChanged([.option], at: t))
        _ = g.handle(.modifiersChanged(both, at: t + 0.01))
        _ = g.handle(.modifiersChanged([.command], at: t + hold))
        return g.handle(.modifiersChanged([], at: t + hold + 0.01))
    }

    @Test func twoQuickTapsTrigger() {
        var g = Gesture()
        #expect(tap(&g, at: 0) == false)
        #expect(tap(&g, at: 0.2) == true)
    }

    @Test func singleTapDoesNothing() {
        var g = Gesture()
        #expect(tap(&g, at: 0) == false)
        // A later lone tap after the timeout is again just a first tap.
        #expect(tap(&g, at: 2) == false)
    }

    @Test func secondTapAfterTimeoutStartsNewGesture() {
        var g = Gesture()
        #expect(tap(&g, at: 0) == false)
        #expect(tap(&g, at: 0.6) == false)
        #expect(tap(&g, at: 0.8) == true)
    }

    @Test func keyDownBetweenTapsCancels() {
        var g = Gesture()
        _ = tap(&g, at: 0)
        _ = g.handle(.keyDown)
        #expect(tap(&g, at: 0.2) == false)
    }

    @Test func keyDownDuringTapCancels() {
        // ⌥⌘T: both held, then a letter, then release.
        var g = Gesture()
        _ = g.handle(.modifiersChanged(both, at: 0))
        _ = g.handle(.keyDown)
        _ = g.handle(.modifiersChanged([], at: 0.1))
        #expect(tap(&g, at: 0.2) == false)
    }

    @Test func extraModifierCancels() {
        var g = Gesture()
        _ = tap(&g, at: 0)
        _ = g.handle(.modifiersChanged([.option, .command, .other], at: 0.2))
        _ = g.handle(.modifiersChanged([], at: 0.25))
        #expect(g.handle(.modifiersChanged(both, at: 0.3)) == false)
        #expect(g.handle(.modifiersChanged([], at: 0.35)) == false)
    }

    @Test func triggersOnlyOnceUntilNextDoubleTap() {
        var g = Gesture()
        _ = tap(&g, at: 0)
        #expect(tap(&g, at: 0.2) == true)
        #expect(tap(&g, at: 0.3) == false)
        #expect(tap(&g, at: 0.45) == true)
    }

    @Test func keyTakenByPushToTalkCancelsTheTapWhileTheOtherSideStillWorks() {
        let left = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags([.option, .command]).rawValue
            | PushToTalkService.DeviceModifierMask.leftOption | PushToTalkService.DeviceModifierMask.leftCommand)
        let right = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags([.option, .command]).rawValue
            | PushToTalkService.DeviceModifierMask.rightOption | PushToTalkService.DeviceModifierMask.leftCommand)
        #expect(InplaceTranslationHotkeyMonitor.modifiers(from: left, reserved: [.rightOption]) == .optionCommand,
                "Left Option + Command is free while Right Option records dictation")
        #expect(InplaceTranslationHotkeyMonitor.modifiers(from: right, reserved: [.rightOption]).contains(.other),
                "Right Option belongs to dictation, so it does not count as a tap")
        #expect(InplaceTranslationHotkeyMonitor.modifiers(from: right, reserved: []) == .optionCommand)
    }

    @Test func modifierMappingIgnoresCapsLockAndFlagsOtherModifiers() {
        let m = InplaceTranslationHotkeyMonitor.modifiers(from: [.option, .command, .capsLock])
        #expect(m == .optionCommand)
        let withShift = InplaceTranslationHotkeyMonitor.modifiers(from: [.option, .command, .shift])
        #expect(withShift.contains(.other))
    }
}

struct InplaceTranslationAnchorTests {
    private let screen = InplaceTranslationAnchor.ScreenInfo(
        frame: CGRect(x: 0, y: 0, width: 1000, height: 800),
        visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 780)
    )
    private let size = CGSize(width: 28, height: 28)

    @Test func axRectConvertsToAppKitCoordinates() {
        let r = InplaceTranslationAnchor.appKitRect(
            fromAX: CGRect(x: 10, y: 100, width: 50, height: 20), primaryScreenHeight: 800
        )
        #expect(r == CGRect(x: 10, y: 680, width: 50, height: 20))
    }

    @Test func placesBadgeRightOfSelectionEnd() {
        let rect = CGRect(x: 200, y: 400, width: 40, height: 20)
        let f = InplaceTranslationAnchor.panelFrame(size: size, selectionEnd: rect, mouse: .zero, screens: [screen])
        #expect(f.minX == 246)
        #expect(f.midY == 410)
    }

    @Test func flipsLeftWhenRightEdgeWouldLeaveScreen() {
        let rect = CGRect(x: 950, y: 400, width: 40, height: 20)
        let f = InplaceTranslationAnchor.panelFrame(size: size, selectionEnd: rect, mouse: .zero, screens: [screen])
        #expect(f.maxX == 944)
    }

    @Test func fallsBackToMouseWhenNoRect() {
        let f = InplaceTranslationAnchor.panelFrame(
            size: size, selectionEnd: nil, mouse: CGPoint(x: 300, y: 300), screens: [screen]
        )
        #expect(f.origin == CGPoint(x: 312, y: 260))
    }

    @Test func fallsBackToMouseWhenRectIsOffScreen() {
        let f = InplaceTranslationAnchor.panelFrame(
            size: size, selectionEnd: CGRect(x: 5000, y: 5000, width: 10, height: 10),
            mouse: CGPoint(x: 300, y: 300), screens: [screen]
        )
        #expect(f.origin == CGPoint(x: 312, y: 260))
    }

    @Test func clampsInsideVisibleFrame() {
        let f = InplaceTranslationAnchor.panelFrame(
            size: size, selectionEnd: nil, mouse: CGPoint(x: 995, y: 2), screens: [screen]
        )
        #expect(f.minX == CGFloat(964))
        #expect(f.minY == 8)
    }
}

struct InplaceTranslationPolicyTests {
    @Test func quotaErrorMapsToQuotaToast() {
        #expect(InplaceTranslationService.toast(for: TranslationError.quotaExceeded) == .quotaFailure)
    }

    @Test func otherErrorsMapToNetworkToast() {
        #expect(InplaceTranslationService.toast(for: URLError(.notConnectedToInternet)) == .networkFailure)
        #expect(InplaceTranslationService.toast(for: InplaceTranslationService.FlowError.timeout) == .networkFailure)
    }

    @Test func timeoutFiresWhenOperationIsSlow() async {
        await #expect(throws: InplaceTranslationService.FlowError.self) {
            try await InplaceTranslationService.withTimeout(seconds: 0.05) {
                try await Task.sleep(for: .seconds(5))
                return 1
            }
        }
    }

    @Test func fastOperationReturnsResult() async throws {
        let v = try await InplaceTranslationService.withTimeout(seconds: 5) { 42 }
        #expect(v == 42)
    }

    @Test func onlyAPushToTalkOnBothSidesBlocksTheGesture() {
        let reserved = PushToTalkKey.reservedForInplaceTranslation([
            (.rightOption, true), (.rightShift, true), (.leftCommand, false)
        ])
        #expect(reserved == [.rightOption], "Only active Option/Command push-to-talk keys are taken")
        #expect(!PushToTalkKey.blocksInplaceTranslation([]))
        #expect(!PushToTalkKey.blocksInplaceTranslation([.rightOption]), "Left Option is still free")
        #expect(!PushToTalkKey.blocksInplaceTranslation([.rightOption, .leftCommand]))
        #expect(PushToTalkKey.blocksInplaceTranslation([.leftOption, .rightOption]))
        #expect(PushToTalkKey.blocksInplaceTranslation([.leftCommand, .rightCommand]))
    }

    @Test func optionAndCommandKeysConflict() {
        #expect(PushToTalkKey.rightOption.isOptionOrCommand)
        #expect(PushToTalkKey.leftCommand.isOptionOrCommand)
        #expect(!PushToTalkKey.rightShift.isOptionOrCommand)
        #expect(!PushToTalkKey.none.isOptionOrCommand)
    }
}

struct InplaceTranslationDirectionTests {
    private let pair = TranslationLanguagePair(languageA: "en", languageB: "uk")

    @Test func englishTextGoesToUkrainian() {
        let result = InplaceTranslationService.direction(for: "Good morning, how are you doing today?", pair: pair)
        #expect(result.source == "en")
        #expect(result.target == "uk")
    }

    @Test func ukrainianTextGoesToEnglish() {
        let result = InplaceTranslationService.direction(for: "Доброго ранку, як у тебе справи сьогодні?", pair: pair)
        #expect(result.source == "uk")
        #expect(result.target == "en")
    }
}

/// Configurable chord and count (WP-15, test-plan T5-IP-02 to T5-IP-09).
struct InplaceTranslationConfiguredGestureTests {
    private typealias Gesture = InplaceTranslationGesture
    private typealias Mods = Gesture.Modifiers

    /// One tap of `chord`: all chord keys down at `t`, all up at `t + 0.08`.
    private func tap(_ g: inout Gesture, _ chord: Mods, at t: TimeInterval) -> Bool {
        _ = g.handle(.modifiersChanged(chord, at: t))
        return g.handle(.modifiersChanged([], at: t + 0.08))
    }

    @Test("T5-IP-02 second press at 0.34 s triggers; at 0.35 s it starts a new gesture")
    func windowBoundary() {
        var early = Gesture()
        #expect(!tap(&early, .optionCommand, at: 0))
        #expect(tap(&early, .optionCommand, at: 0.34))

        var late = Gesture()
        #expect(!tap(&late, .optionCommand, at: 0))
        #expect(!tap(&late, .optionCommand, at: 0.35))
        #expect(tap(&late, .optionCommand, at: 0.5), "The 0.35 s press was the first of a new gesture")
    }

    @Test("T5-IP-03 a configured chord: ⌥⌘ does nothing, ⌃⌥ triggers")
    func configuredChord() {
        let controlOption: Mods = [.control, .option]
        var g = Gesture(chord: controlOption, pressCount: 2)
        #expect(!tap(&g, .optionCommand, at: 0))
        #expect(!tap(&g, .optionCommand, at: 0.1))
        #expect(!tap(&g, controlOption, at: 2))
        #expect(tap(&g, controlOption, at: 2.1))

        #expect(InplaceTranslationHotkeyMonitor.modifiers(from: [.control, .option], chord: [.control, .option])
            == controlOption)
        #expect(InplaceTranslationHotkeyMonitor.modifiers(from: [.option, .command], chord: [.control, .option])
            .contains(.other), "⌘ is not part of the chord")
    }

    @Test("T5-IP-04 a configured count of 3")
    func configuredCountThree() {
        var g = Gesture(chord: .optionCommand, pressCount: 3)
        #expect(!tap(&g, .optionCommand, at: 0))
        #expect(!tap(&g, .optionCommand, at: 0.2))
        #expect(!tap(&g, .optionCommand, at: 2))
        #expect(!tap(&g, .optionCommand, at: 2.2))
        #expect(!tap(&g, .optionCommand, at: 3))
        #expect(!tap(&g, .optionCommand, at: 3.2))
        #expect(tap(&g, .optionCommand, at: 3.4))
    }

    @Test("T5-IP-05 1x on a modifier chord is not allowed and reads as 2")
    func singlePressOnModifierChordIsRejected() {
        #expect(Gesture(chord: .optionCommand, pressCount: 1).pressCount == 2)
        var g = Gesture(chord: .optionCommand, pressCount: 1)
        #expect(!tap(&g, .optionCommand, at: 0))
        #expect(tap(&g, .optionCommand, at: 0.2))
    }

    @Test("T5-IP-07 push-to-talk on both sides blocks only the families in the chord")
    func pushToTalkBlocksChordFamilies() {
        let controls: Set<PushToTalkKey> = [.leftControl, .rightControl]
        #expect(PushToTalkKey.blocksInplaceTranslation(controls, chord: [.control, .option]))
        #expect(!PushToTalkKey.blocksInplaceTranslation(controls, chord: [.option, .command]))
        #expect(PushToTalkKey.reservedForInplaceTranslation(
            [(.rightControl, true), (.rightShift, true)], chord: [.control, .option]
        ) == [.rightControl])
    }
}

/// The monitor on a fake key source and a fake registrar.
@MainActor
final class InplaceTranslationMonitorTests {
    private typealias Mask = PushToTalkService.DeviceModifierMask

    private let source = FakeKeySource()
    private let registrar = FakeHotkeyRegistrar()
    private let clock = ManualClock(50)
    private lazy var session = ShortcutCaptureSession(registrar: registrar, notifications: NotificationCenter())
    private lazy var sut = InplaceTranslationHotkeyMonitor(
        source: source,
        registrar: registrar,
        clock: clock,
        captureSession: session
    )
    private var triggers = 0

    init() {
        sut.onTrigger = { [unowned self] in triggers += 1 }
    }

    private func tapOptionCommand(at t: TimeInterval) {
        let both = NSEvent.ModifierFlags([.option, .command]).rawValue | Mask.leftOption | Mask.leftCommand
        source.send(.flags(KeyCode.leftOption, NSEvent.ModifierFlags.option.rawValue | Mask.leftOption, at: t))
        source.send(.flags(KeyCode.leftCommand, both, at: t + 0.01))
        source.send(.flags(KeyCode.leftCommand, NSEvent.ModifierFlags.option.rawValue | Mask.leftOption, at: t + 0.08))
        source.send(.flags(KeyCode.leftOption, 0, at: t + 0.09))
    }

    @Test("T5-IP-01 default ⌥⌘ double tap through the key source")
    func defaultDoubleTap() {
        sut.start()
        tapOptionCommand(at: 0)
        tapOptionCommand(at: 0.2)
        #expect(triggers == 1)
    }

    @Test("A key-down between taps cancels")
    func keyDownBetweenTapsCancels() {
        sut.start()
        tapOptionCommand(at: 0)
        source.send(.key(KeyCode.i, [.option, .command], at: 0.12))
        tapOptionCommand(at: 0.2)
        #expect(triggers == 0)
    }

    @Test("T5-IP-06 a key chord ⌃⌥I at 1x triggers through the registrar")
    func keyChordTriggers() {
        let chord = KeyboardShortcuts.Shortcut(.i, modifiers: [.control, .option])
        registrar.setShortcut(chord, for: .inplaceTranslation)
        sut.configure(shortcut: .keyChord, pressCount: 1)
        sut.start()

        #expect(!source.isActive, "A key chord does not watch every key")
        #expect(registrar.isEnabled(.inplaceTranslation))
        registrar.fire(keys: chord)
        #expect(triggers == 1)
    }

    @Test("A key chord at 2x counts with the 0.35 s hotkey window")
    func keyChordCountsPresses() {
        registrar.setShortcut(.init(.i, modifiers: [.control, .option]), for: .inplaceTranslation)
        sut.configure(shortcut: .keyChord, pressCount: 2)
        sut.start()

        registrar.fire(.inplaceTranslation)
        #expect(triggers == 0)
        clock.advance(by: 0.2)
        registrar.fire(.inplaceTranslation)
        #expect(triggers == 1)
    }

    @Test("T5-IP-08 stop turns both paths off")
    func stopTurnsOff() {
        sut.start()
        #expect(sut.isRunning)
        sut.stop()
        #expect(!sut.isRunning)
        #expect(!source.isActive)

        registrar.setShortcut(.init(.i, modifiers: [.control, .option]), for: .inplaceTranslation)
        sut.configure(shortcut: .keyChord, pressCount: 1)
        sut.start()
        sut.stop()
        #expect(!sut.isRunning)
        #expect(!registrar.isEnabled(.inplaceTranslation))
    }

    @Test("Switching from a key chord to a modifier chord unregisters the Carbon hotkey")
    func switchingKindsKeepsOnePath() {
        registrar.setShortcut(.init(.i, modifiers: [.control, .option]), for: .inplaceTranslation)
        sut.configure(shortcut: .keyChord, pressCount: 1)
        sut.start()
        sut.configure(shortcut: .modifierChord([.control, .option]), pressCount: 2)

        #expect(sut.isRunning)
        #expect(source.isActive)
        #expect(!registrar.isEnabled(.inplaceTranslation))
    }

    @Test("A key chord is off during capture and back after it")
    func keyChordAcrossCapture() {
        registrar.setShortcut(.init(.i, modifiers: [.control, .option]), for: .inplaceTranslation)
        sut.configure(shortcut: .keyChord, pressCount: 1)
        sut.start()
        session.begin()
        #expect(!registrar.isEnabled(.inplaceTranslation))
        session.end()
        #expect(registrar.isEnabled(.inplaceTranslation))
    }

    @Test("A key chord stopped during capture stays off; one started during capture waits")
    func keyChordChangedDuringCapture() {
        registrar.setShortcut(.init(.i, modifiers: [.control, .option]), for: .inplaceTranslation)
        sut.configure(shortcut: .keyChord, pressCount: 1)
        sut.start()
        session.begin()
        sut.stop()
        session.end()
        #expect(!registrar.isEnabled(.inplaceTranslation))

        session.begin()
        sut.start()
        #expect(!registrar.isEnabled(.inplaceTranslation))
        session.end()
        #expect(registrar.isEnabled(.inplaceTranslation))
    }

    @Test("Taps are ignored while a shortcut is being captured")
    func ignoredDuringCapture() {
        sut.start()
        session.begin()
        tapOptionCommand(at: 0)
        tapOptionCommand(at: 0.2)
        #expect(triggers == 0)
        session.end()
        tapOptionCommand(at: 2)
        tapOptionCommand(at: 2.2)
        #expect(triggers == 1)
    }
}

struct InplaceTranslationPairDirectionTests {
    @Test("T5-IP-09 the direction follows the pair en-pl")
    func directionFollowsPair() {
        let pair = TranslationLanguagePair(languageA: "en", languageB: "pl")
        #expect(InplaceTranslationService.direction(for: "Good morning, how are you doing today?", pair: pair).target == "pl")
        #expect(InplaceTranslationService.direction(for: "Dzień dobry, jak się dzisiaj masz?", pair: pair).target == "en")
    }
}
