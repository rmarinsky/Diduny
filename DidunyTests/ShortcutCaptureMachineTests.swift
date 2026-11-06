import AppKit
@testable import Diduny
import KeyboardShortcuts
import Testing

/// Capture rules for the two special rows (ADR-0012 D8), without AppKit windows.
struct ShortcutCaptureMachineTests {
    private typealias Machine = ShortcutCaptureMachine

    private let option = NSEvent.ModifierFlags.option.rawValue
    private let optionCommand = NSEvent.ModifierFlags([.option, .command]).rawValue

    // MARK: - Cancel row (.singleKey)

    @Test("Cancel: Esc is a value, not an abort")
    func escIsAValue() {
        var m = Machine(mode: .singleKey)
        #expect(m.handle(.key(KeyCode.escape)) == .commit(.cancelKey(.defaultShortcut)))
        #expect(m.isFinished)
    }

    @Test("Cancel: a bare F key is accepted")
    func bareFunctionKey() {
        var m = Machine(mode: .singleKey)
        let output = m.handle(.key(KeyCode.f5, [.function]))
        #expect(output == .commit(.cancelKey(RecordingCancelShortcut(keyCode: KeyCode.f5, modifiersRawValue: 0, keyLabel: "F5"))))
    }

    @Test("Cancel: a key with ⌘, ⌥ or ⌃ is accepted, with its label")
    func keyWithModifier() {
        var m = Machine(mode: .singleKey)
        let output = m.handle(.key(KeyCode.x, [.control], characters: "x"))
        guard case let .commit(.cancelKey(shortcut)) = output else {
            Issue.record("Expected a cancel key, got \(output)")
            return
        }
        #expect(shortcut.keyCode == KeyCode.x)
        #expect(shortcut.modifiersRawValue == NSEvent.ModifierFlags.control.rawValue)
        #expect(shortcut.displayName == "⌃X")
    }

    @Test("Cancel: a bare letter, or one with only ⇧, is refused and capture continues")
    func bareLetterRefused() {
        var m = Machine(mode: .singleKey)
        #expect(m.handle(.key(KeyCode.a, characters: "a")) == .reject(.needsModifier))
        #expect(m.handle(.key(KeyCode.a, [.shift], characters: "a")) == .reject(.needsModifier))
        #expect(!m.isFinished)
        #expect(m.handle(.key(KeyCode.escape)) == .commit(.cancelKey(.defaultShortcut)))
    }

    @Test("Cancel: Tab aborts, Delete resets to Esc")
    func tabAbortsDeleteResets() {
        var tab = Machine(mode: .singleKey)
        #expect(tab.handle(.key(KeyCode.tab)) == .abort)

        var delete = Machine(mode: .singleKey)
        #expect(delete.handle(.key(KeyCode.delete)) == .commit(.cancelKey(.defaultShortcut)))
    }

    @Test("Cancel: repeats and modifier changes are ignored")
    func repeatsIgnored() {
        var m = Machine(mode: .singleKey)
        #expect(m.handle(.key(KeyCode.x, [.control], isRepeat: true)) == .pending)
        #expect(m.handle(.flags(KeyCode.leftControl, NSEvent.ModifierFlags.control)) == .pending)
        #expect(!m.isFinished)
    }

    @Test("Abort from outside (click outside, loss of key) ends capture")
    func externalAbort() {
        var m = Machine(mode: .singleKey)
        #expect(m.abort() == .abort)
        #expect(m.isFinished)
        #expect(m.handle(.key(KeyCode.escape)) == .pending)
    }

    // MARK: - In-place row (.chordOrModifiers)

    @Test("In place: two families pressed and released commit a modifier chord")
    func modifierChordCommits() {
        var m = Machine(mode: .chordOrModifiers)
        #expect(m.handle(.flags(KeyCode.leftOption, option)) == .pending)
        #expect(m.handle(.flags(KeyCode.leftCommand, optionCommand)) == .pending)
        #expect(m.handle(.flags(KeyCode.leftCommand, option)) == .pending)
        #expect(m.handle(.flags(KeyCode.leftOption, 0)) == .commit(.modifierChord([.option, .command])))
    }

    @Test("In place: a single family is ignored and capture continues")
    func singleFamilyIgnored() {
        var m = Machine(mode: .chordOrModifiers)
        #expect(m.handle(.flags(KeyCode.leftOption, option)) == .pending)
        #expect(m.handle(.flags(KeyCode.leftOption, 0)) == .pending)
        #expect(!m.isFinished)

        let controlOption = NSEvent.ModifierFlags([.control, .option]).rawValue
        _ = m.handle(.flags(KeyCode.leftControl, controlOption))
        #expect(m.handle(.flags(KeyCode.leftControl, 0)) == .commit(.modifierChord([.control, .option])))
    }

    @Test("In place: a key with ⌘ ⌥ or ⌃ commits a key chord")
    func keyChordCommits() {
        var m = Machine(mode: .chordOrModifiers)
        _ = m.handle(.flags(KeyCode.leftOption, optionCommand))
        let output = m.handle(.key(KeyCode.i, [.option, .command]))
        #expect(output == .commit(.keyChord(.init(.i, modifiers: [.option, .command]))))
        #expect(m.handle(.flags(KeyCode.leftOption, 0)) == .pending, "Release after the commit adds nothing")
    }

    @Test("In place: a bare F key is a key chord; a bare letter is refused")
    func bareKeys() {
        var letter = Machine(mode: .chordOrModifiers)
        #expect(letter.handle(.key(KeyCode.i)) == .reject(.needsModifier))
        #expect(!letter.isFinished)

        var function = Machine(mode: .chordOrModifiers)
        #expect(function.handle(.key(KeyCode.f6, [.function])) == .commit(.keyChord(.init(.f6))))
    }

    @Test("In place: bare Esc aborts and restores the old value")
    func escAborts() {
        var m = Machine(mode: .chordOrModifiers)
        #expect(m.handle(.key(KeyCode.escape)) == .abort)
    }

    @Test("In place: a chord another Diduny shortcut uses is refused; the release does not commit ⌥⌘")
    func takenChordRefused() {
        let dictation = KeyboardShortcuts.Shortcut(.d, modifiers: [.option, .command])
        var m = Machine(mode: .chordOrModifiers, takenShortcuts: [.toggleRecording: dictation])
        _ = m.handle(.flags(KeyCode.leftOption, optionCommand))
        #expect(m.handle(.key(KeyCode.d, [.option, .command])) == .reject(.alreadyUsed(.toggleRecording)))
        #expect(m.handle(.flags(KeyCode.leftOption, 0)) == .pending)
        #expect(!m.isFinished)
    }
}

/// The session that silences Diduny's own hotkeys while a special row captures.
struct ShortcutCaptureSessionTests {
    @Test("Begin disables every enabled hotkey; end re-enables exactly those")
    func beginAndEnd() {
        let registrar = FakeHotkeyRegistrar()
        let enabled: [KeyboardShortcuts.Name] = [.toggleRecording, .translateSelectedText, .toggleHistoryPalette]
        enabled.forEach(registrar.enable)
        let session = ShortcutCaptureSession(registrar: registrar)

        session.begin()
        #expect(session.isActive)
        for name in ShortcutCaptureSession.managedNames {
            #expect(!registrar.isEnabled(name), "\(name.rawValue)")
        }

        session.end()
        #expect(!session.isActive)
        for name in enabled {
            #expect(registrar.isEnabled(name), "\(name.rawValue) is re-enabled")
        }
        #expect(!registrar.isEnabled(.forceSubmit), "Force submit was off while idle and stays off")
        #expect(!registrar.isEnabled(.addMeetingChapter))
    }

    @Test("The in-place key chord is part of the managed names")
    func managedNamesIncludeInplace() {
        #expect(ShortcutCaptureSession.managedNames.contains(.inplaceTranslation))
        #expect(ShortcutCaptureSession.managedNames.count == 9)
    }

    @Test("End without begin, and a second begin, change nothing")
    func idempotent() {
        let registrar = FakeHotkeyRegistrar()
        registrar.enable(.toggleRecording)
        let session = ShortcutCaptureSession(registrar: registrar)
        session.end()
        #expect(registrar.isEnabled(.toggleRecording))

        session.begin()
        session.begin()
        session.end()
        #expect(registrar.isEnabled(.toggleRecording))
    }
}
