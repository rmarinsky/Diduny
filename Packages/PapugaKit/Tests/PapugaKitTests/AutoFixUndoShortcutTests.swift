import AppKit
import CoreGraphics
import XCTest
@testable import PapugaKit

/// The undo shortcut arrives at the event tap on keyDown but is delivered by
/// `KeyboardShortcuts` on keyUp. `processEvent` has to recognise it on the way in,
/// otherwise one of its reset branches clears `lastFix` and the handler that fires a
/// moment later finds nothing to undo.
final class AutoFixUndoShortcutTests: XCTestCase {
    private let zKeyCode: UInt16 = 6 // kVK_ANSI_Z

    func test_matchesShortcut_recognizesTheExactRecordedChord() {
        XCTAssertTrue(AutoFixController.matchesShortcut(
            keyCode: zKeyCode,
            flags: [.maskCommand],
            carbonKeyCode: Int(zKeyCode),
            modifiers: .command
        ))
    }

    func test_matchesShortcut_ignoresFlagsAShortcutCanNeverCarry() {
        // A tap reports Caps Lock and numeric-keypad state alongside the real modifiers;
        // a recorded shortcut holds neither, so raw flag equality would never match.
        XCTAssertTrue(AutoFixController.matchesShortcut(
            keyCode: zKeyCode,
            flags: [.maskCommand, .maskAlphaShift, .maskNumericPad],
            carbonKeyCode: Int(zKeyCode),
            modifiers: .command
        ))
    }

    func test_matchesShortcut_rejectsAnExtraModifier() {
        XCTAssertFalse(AutoFixController.matchesShortcut(
            keyCode: zKeyCode,
            flags: [.maskCommand, .maskShift],
            carbonKeyCode: Int(zKeyCode),
            modifiers: .command
        ))
    }

    func test_matchesShortcut_rejectsAMissingModifier() {
        XCTAssertFalse(AutoFixController.matchesShortcut(
            keyCode: zKeyCode,
            flags: [],
            carbonKeyCode: Int(zKeyCode),
            modifiers: .command
        ))
    }

    func test_matchesShortcut_rejectsADifferentKey() {
        XCTAssertFalse(AutoFixController.matchesShortcut(
            keyCode: 7, // X
            flags: [.maskCommand],
            carbonKeyCode: Int(zKeyCode),
            modifiers: .command
        ))
    }

    func test_matchesShortcut_isFalseWhenNoShortcutIsAssigned() {
        XCTAssertFalse(AutoFixController.matchesShortcut(
            keyCode: zKeyCode,
            flags: [.maskCommand],
            carbonKeyCode: nil,
            modifiers: []
        ))
    }

    func test_onlyTextTypesOverAProposal() {
        XCTAssertTrue(AutoFixKeyEventText.typesOverProposal("a", flags: []))
        XCTAssertTrue(AutoFixKeyEventText.typesOverProposal(" ", flags: []))
        XCTAssertFalse(AutoFixKeyEventText.typesOverProposal("\t", flags: []), "Tab moves focus")
        XCTAssertFalse(AutoFixKeyEventText.typesOverProposal("\r", flags: []))
        XCTAssertFalse(AutoFixKeyEventText.typesOverProposal("", flags: []), "arrows carry no text")
        XCTAssertFalse(AutoFixKeyEventText.typesOverProposal("z", flags: .maskCommand))
        XCTAssertFalse(AutoFixKeyEventText.typesOverProposal("a", flags: .maskControl))
    }
}
