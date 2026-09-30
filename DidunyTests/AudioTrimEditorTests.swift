@testable import Diduny
import XCTest

final class AudioTrimEditorTests: XCTestCase {
    func testDragIsOneUndoAndNewEditClearsRedo() {
        var editor = AudioTrimEditorState(duration: 28800, savedRange: nil)
        editor.beginGesture()
        editor.setEnd(7200)
        editor.setEnd(4500)
        editor.endGesture()
        XCTAssertEqual(editor.range.endSeconds, 4500)
        editor.undo()
        XCTAssertEqual(editor.range.endSeconds, 28800)
        XCTAssertFalse(editor.canUndo)
        XCTAssertTrue(editor.canRedo)
        editor.redo()
        XCTAssertEqual(editor.range.endSeconds, 4500)
        editor.undo()
        editor.setStart(60)
        XCTAssertFalse(editor.canRedo)
        XCTAssertTrue(editor.isDirty)
    }

    func testRestoreOriginalCanBeUndoneAndCancelLeavesSavedRange() {
        let saved = AudioTrimRange(startSeconds: 60, endSeconds: 4500)
        var editor = AudioTrimEditorState(duration: 28800, savedRange: saved)
        XCTAssertFalse(editor.isDirty)
        editor.restoreOriginal()
        XCTAssertTrue(editor.isDirty)
        editor.undo()
        XCTAssertEqual(editor.range, saved)
        XCTAssertFalse(editor.isDirty)
        editor.setEnd(5000)
        editor.cancel()
        XCTAssertEqual(editor.range, saved)
        XCTAssertFalse(editor.isDirty)
    }

    func testTimeFieldsRejectInvalidInputAndClampHandles() {
        var editor = AudioTrimEditorState(duration: 28800, savedRange: nil)
        XCTAssertFalse(editor.setTime("00:90:00", isStart: false))
        XCTAssertFalse(editor.setTime("abc", isStart: true))
        XCTAssertFalse(editor.setTime("09:00:00", isStart: false))
        XCTAssertTrue(editor.setTime("01:15:00", isStart: false))
        editor.setStart(6000)
        XCTAssertLessThan(editor.range.startSeconds, editor.range.endSeconds)
        XCTAssertEqual(editor.range.endSeconds, 4500)
    }
    func testIncompleteTimeDraftBlocksSaveAndRemainsDirty() {
        var editor = AudioTrimEditorState(duration: 28800, savedRange: nil)
        editor.editTime("01:15:00", isStart: false)
        editor.editTime("00:12", isStart: false)
        XCTAssertTrue(editor.hasInvalidTime)
        XCTAssertTrue(editor.isDirty)
        XCTAssertFalse(editor.commitTimeFields())
        editor.editTime("00:01:00", isStart: true)
        XCTAssertTrue(editor.hasInvalidTime)
        editor.editTime("01:15:00", isStart: false)
        XCTAssertFalse(editor.hasInvalidTime)
        XCTAssertTrue(editor.commitTimeFields())
        XCTAssertEqual(editor.range.startSeconds, 60)
        XCTAssertEqual(editor.range.endSeconds, 4500)
    }

    func testChangingFromFieldToDragPreservesBothUndoSteps() {
        var editor = AudioTrimEditorState(duration: 28800, savedRange: nil)
        editor.beginGesture()
        editor.setEnd(4500)
        editor.beginGesture()
        editor.setStart(60)
        editor.endGesture()
        editor.undo()
        XCTAssertEqual(editor.range, AudioTrimRange(startSeconds: 0, endSeconds: 4500))
        editor.undo()
        XCTAssertEqual(editor.range, AudioTrimRange(startSeconds: 0, endSeconds: 28800))
    }
    func testUndoCommitsAndRevertsAnActiveFieldEdit() {
        var editor = AudioTrimEditorState(duration: 28800, savedRange: nil)
        editor.beginGesture()
        editor.setEnd(4500)
        XCTAssertTrue(editor.canUndo)
        editor.undo()
        XCTAssertEqual(editor.range.endSeconds, 28800)
        XCTAssertTrue(editor.canRedo)
    }
    func testIncompleteFirstTimeEditCanBeUndoneAndRedone() {
        var editor = AudioTrimEditorState(duration: 28800, savedRange: nil)
        editor.beginGesture()
        editor.editTime("00:12", isStart: false)
        editor.endGesture()
        XCTAssertTrue(editor.canUndo)
        editor.undo()
        XCTAssertEqual(editor.endText, "08:00:00")
        XCTAssertFalse(editor.hasInvalidTime)
        editor.redo()
        XCTAssertEqual(editor.endText, "00:12")
        XCTAssertTrue(editor.hasInvalidTime)
    }
}
