import CoreGraphics
import XCTest
@testable import PapugaKit

final class AutoFixTargetValidatorTests: XCTestCase {
    func test_papugaSyntheticEventTag_isRecognizedByEventTapFilter() throws {
        let event = try XCTUnwrap(CGEvent(
            keyboardEventSource: nil,
            virtualKey: 0,
            keyDown: true
        ))

        XCTAssertFalse(PapugaSyntheticEvent.isTagged(event))
        PapugaSyntheticEvent.tag(event)
        XCTAssertTrue(PapugaSyntheticEvent.isTagged(event))
    }

    func test_replacementAnchor_excludesSpaceBoundary() throws {
        let range = try XCTUnwrap(TextReplacementAnchor.sourceRange(
            caretAfterBoundary: 8,
            source: "привіт",
            boundary: " "
        ))

        XCTAssertEqual(range, AXTextRange(location: 1, length: 6))
    }

    func test_replacementAnchor_excludesReturnAndTabBoundaries() throws {
        XCTAssertEqual(
            TextReplacementAnchor.sourceRange(caretAfterBoundary: 7, source: "привіт", boundary: "\r"),
            AXTextRange(location: 0, length: 6)
        )
        XCTAssertEqual(
            TextReplacementAnchor.sourceRange(caretAfterBoundary: 7, source: "привіт", boundary: "\t"),
            AXTextRange(location: 0, length: 6)
        )
    }

    func test_replacementAnchor_usesUTF16ForComposedText() throws {
        let source = "e\u{301}🙂"
        let range = try XCTUnwrap(TextReplacementAnchor.sourceRange(
            caretAfterBoundary: 9,
            source: source,
            boundary: " "
        ))

        XCTAssertEqual(source.count, 2)
        XCTAssertEqual(source.utf16.count, 4)
        XCTAssertEqual(range, AXTextRange(location: 4, length: 4))
    }

    func test_sentenceReplacementAnchor_excludesTrailingListBoundary() throws {
        let source = "vj;yf 👨‍👩‍👧‍👦 dbrjhbcnfnb"
        let prefixUTF16Length = 11
        let boundary = "\r"
        let caret = prefixUTF16Length + source.utf16.count + boundary.utf16.count

        let range = try XCTUnwrap(TextReplacementAnchor.sourceRange(
            caretAfterBoundary: caret,
            source: source,
            boundary: boundary
        ))

        XCTAssertEqual(range.location, prefixUTF16Length)
        XCTAssertEqual(range.length, source.utf16.count)
        XCTAssertEqual(range.location + range.length, caret - boundary.utf16.count)
    }

    func test_replacementAnchor_canLeaveAWholeOverflowSuffixUntouched() throws {
        let source = "first incident"
        let untouchedSuffix = " overflow word "
        let caret = source.utf16.count + untouchedSuffix.utf16.count

        XCTAssertEqual(
            TextReplacementAnchor.sourceRange(
                caretAfterBoundary: caret,
                source: source,
                boundary: untouchedSuffix
            ),
            AXTextRange(location: 0, length: source.utf16.count)
        )
    }

    func test_replacementAnchor_rejectsCaretBeforeSourceAndBoundary() {
        XCTAssertNil(TextReplacementAnchor.sourceRange(
            caretAfterBoundary: 3,
            source: "привіт",
            boundary: " "
        ))
    }

    func test_replacementCommit_rejectsAXSuccessWhenEditorTextDidNotChange() {
        let replacementRange = AXTextRange(location: 12, length: 5)

        XCTAssertFalse(AutoFixTargetValidator.replacementWasCommitted(
            expected: "роблю",
            at: replacementRange,
            readString: { requestedRange in
                XCTAssertEqual(requestedRange, replacementRange)
                return "hj,k"
            }
        ))
    }

    func test_replacementCommit_acceptsExactEditorReadback() {
        let replacementRange = AXTextRange(location: 12, length: 5)

        XCTAssertTrue(AutoFixTargetValidator.replacementWasCommitted(
            expected: "роблю",
            at: replacementRange,
            readString: { requestedRange in
                XCTAssertEqual(requestedRange, replacementRange)
                return "роблю"
            }
        ))
    }

    func test_replacementCommit_pollingAcceptsDelayedExactReadback() {
        let replacementRange = AXTextRange(location: 12, length: 5)
        var reads = 0
        var delays = 0

        XCTAssertTrue(AutoFixTargetValidator.waitForCommittedReplacement(
            expected: "роблю",
            at: replacementRange,
            attempts: 3,
            retryDelay: { delays += 1 },
            readString: { _ in
                reads += 1
                return reads == 3 ? "роблю" : "hj,k"
            }
        ))
        XCTAssertEqual(reads, 3)
        XCTAssertEqual(delays, 2)
    }

    func test_replacementCommit_pollingRejectsPersistentMismatch() {
        var delays = 0

        XCTAssertFalse(AutoFixTargetValidator.waitForCommittedReplacement(
            expected: "роблю",
            at: AXTextRange(location: 12, length: 5),
            attempts: 3,
            retryDelay: { delays += 1 },
            readString: { _ in "hj,k" }
        ))
        XCTAssertEqual(delays, 2)
    }

    func test_anchorReadback_waitsForDelayedWebEditorText() {
        let sourceRange = AXTextRange(location: 4, length: 6)
        var reads = 0
        var delays = 0

        XCTAssertTrue(AutoFixTargetValidator.waitForReadableAnchor(
            source: "ghbdsn",
            boundary: " ",
            sourceRange: sourceRange,
            attempts: 3,
            retryDelay: { delays += 1 },
            readString: { range in
                XCTAssertEqual(range, AXTextRange(location: 4, length: 7))
                reads += 1
                return reads == 1 ? "ghbdsn" : "ghbdsn "
            }
        ))
        XCTAssertEqual(reads, 2)
        XCTAssertEqual(delays, 1)
    }

    // MARK: - Return: the key event says CR, the editor stores LF

    func test_readbackBoundaries_acceptsBothRenderingsOfReturnOnly() {
        XCTAssertEqual(AutoFixTargetValidator.readbackBoundaries("\r"), ["\n", "\r"])
        XCTAssertEqual(AutoFixTargetValidator.readbackBoundaries(" "), [" "])
        XCTAssertEqual(AutoFixTargetValidator.readbackBoundaries("\t"), ["\t"])
    }

    func test_readableAnchor_acceptsTheNewlineAnEditorActuallyStores() {
        // TextEdit, Notes, every IDE: the tap reported "\r", AXStringForRange returns "\n".
        // Comparing against "\r" alone failed all five attempts and killed the fix.
        var reads = 0

        XCTAssertTrue(AutoFixTargetValidator.waitForReadableAnchor(
            source: "ghbdsn",
            boundary: "\r",
            sourceRange: AXTextRange(location: 4, length: 6),
            attempts: 3,
            retryDelay: {},
            readString: { range in
                XCTAssertEqual(range, AXTextRange(location: 4, length: 7))
                reads += 1
                return "ghbdsn\n"
            }
        ))
        XCTAssertEqual(reads, 1, "both renderings are tried within one attempt")
    }

    func test_readableAnchor_stillAcceptsAnEditorThatReportsCarriageReturn() {
        XCTAssertTrue(AutoFixTargetValidator.waitForReadableAnchor(
            source: "ghbdsn",
            boundary: "\r",
            sourceRange: AXTextRange(location: 4, length: 6),
            attempts: 1,
            retryDelay: {},
            readString: { _ in "ghbdsn\r" }
        ))
    }

    func test_readableAnchor_rejectsTextThatIsNotTheTypedToken() {
        XCTAssertFalse(AutoFixTargetValidator.waitForReadableAnchor(
            source: "ghbdsn",
            boundary: "\r",
            sourceRange: AXTextRange(location: 4, length: 6),
            attempts: 2,
            retryDelay: {},
            readString: { _ in "ghbdsx\n" }
        ))
    }

    func test_valueSuffixRange_anchorsAReturnTerminatedToken() throws {
        let anchor = try XCTUnwrap(AutoFixTargetValidator.valueSuffixRange(
            source: "ddtltyyz",
            boundary: "\r",
            in: "gjvbkrf ddtltyyz\n"
        ))
        XCTAssertEqual(anchor.sourceRange, AXTextRange(location: 8, length: 8))
        XCTAssertEqual(anchor.caretAfterBoundary, 17)
    }

    func test_keyboardFallbackPlan_replacesVerifiedSpaceTerminatedBuffer() throws {
        let plan = try XCTUnwrap(AutoFixTargetValidator.keyboardFallbackPlan(
            source: "ghbdsn",
            boundary: " ",
            replacement: "привіт"
        ))

        XCTAssertEqual(plan.deleteCount, 7)
        XCTAssertEqual(plan.replacement, "привіт ")
        XCTAssertNil(AutoFixTargetValidator.keyboardFallbackPlan(
            source: "ghbdsn",
            boundary: "\r",
            replacement: "привіт"
        ))
    }

    /// This path deletes without being able to read the field back, so the
    /// count is asserted rather than verified. A long `expectedSource` means
    /// the anchor no longer describes reality; do nothing rather than eat an
    /// unknown amount of the user's text.
    func test_keyboardFallbackPlan_refusesToBlindDeleteAnImplausiblyLongToken() {
        let cap = AutoFixTargetValidator.maxUnverifiedDeleteCharacters
        XCTAssertNotNil(AutoFixTargetValidator.keyboardFallbackPlan(
            source: String(repeating: "a", count: cap),
            boundary: " ",
            replacement: "ok"
        ))
        XCTAssertNil(AutoFixTargetValidator.keyboardFallbackPlan(
            source: String(repeating: "a", count: cap + 1),
            boundary: " ",
            replacement: "ok"
        ))
    }

    /// Deleting nothing and then typing would duplicate text rather than
    /// replace it.
    func test_keyboardFallbackPlan_refusesEmptySourceOrReplacement() {
        XCTAssertNil(AutoFixTargetValidator.keyboardFallbackPlan(
            source: "", boundary: " ", replacement: "привіт"
        ))
        XCTAssertNil(AutoFixTargetValidator.keyboardFallbackPlan(
            source: "ghbdsn", boundary: " ", replacement: ""
        ))
    }

    /// Backspace removes one user-perceived character, so the count is
    /// grapheme-based even though every AX range in that file is UTF-16.
    /// Counting UTF-16 here would over-delete on emoji and combining marks.
    func test_keyboardFallbackPlan_countsGraphemesNotUTF16Units() throws {
        let plan = try XCTUnwrap(AutoFixTargetValidator.keyboardFallbackPlan(
            source: "ab🇺🇦é",           // 4 graphemes, more UTF-16 units
            boundary: " ",
            replacement: "ok"
        ))
        XCTAssertEqual(plan.deleteCount, 5, "should be 4 graphemes + the boundary")
        XCTAssertGreaterThan("ab🇺🇦é".utf16.count, 4, "test string must actually differ")
    }

    func test_keyboardFallbackPolicy_acceptsMissingWebEditorSelectionOnlyForSpace() {
        XCTAssertTrue(AutoFixTargetValidator.canUseKeyboardFallback(
            boundary: " ",
            selection: nil,
            sourceRange: nil
        ))
        XCTAssertFalse(AutoFixTargetValidator.canUseKeyboardFallback(
            boundary: "\r",
            selection: nil,
            sourceRange: nil
        ))
        XCTAssertFalse(AutoFixTargetValidator.canUseKeyboardFallback(
            boundary: " ",
            selection: AXTextRange(location: 10, length: 2),
            sourceRange: nil
        ))
    }

    // MARK: - Caret advance: the tap sees a keystroke before the app does

    func test_caretAdvance_acceptsBothOutcomesOfTheRaceWithTheApp() {
        // "hjvfy" + space. The session caret was sampled on the first keystroke,
        // which the target app may or may not have applied by then.
        let advances = AutoFixTargetValidator.acceptableCaretAdvances(
            source: "hjvfy",
            boundary: " ",
            firstCharacter: "h"
        )
        XCTAssertEqual(advances, [5, 6], "first character already inserted, or not yet")
    }

    func test_caretAdvance_coversTheRaceEvenForASingleCharacterWord() {
        // Only the boundary was typed after the session started, so the two readings
        // are "space only" and "the character too" — still genuinely different.
        XCTAssertEqual(
            AutoFixTargetValidator.acceptableCaretAdvances(source: "h", boundary: " ", firstCharacter: "h"),
            [1, 2]
        )
    }

    func test_caretAdvance_collapsesWhenThereIsNoFirstCharacterToRaceOver() {
        XCTAssertEqual(
            AutoFixTargetValidator.acceptableCaretAdvances(source: "hj", boundary: " ", firstCharacter: ""),
            [3],
            "nothing was pending, so there is only one explanation for the caret"
        )
    }

    func test_caretAdvance_isUTF16ForComposedText() {
        let advances = AutoFixTargetValidator.acceptableCaretAdvances(
            source: "ab🇺🇦",
            boundary: " ",
            firstCharacter: "a"
        )
        XCTAssertEqual(advances, ["ab🇺🇦".utf16.count - 1 + 1, "ab🇺🇦".utf16.count + 1])
        XCTAssertGreaterThan("ab🇺🇦".utf16.count, "ab🇺🇦".count, "test string must actually differ")
    }

    func test_typingTarget_acceptsSessionCaretSampledBeforeTheFirstCharacterLanded() {
        // Telegram: caret read as 0 on the first keystroke, sits at 6 once "hjvfy "
        // is in the field. The old single-value arithmetic expected 5 and rejected it.
        let atSessionStart = signature(caret: 0)
        let atBoundary = signature(caret: 6)
        let advances = AutoFixTargetValidator.acceptableCaretAdvances(
            source: "hjvfy",
            boundary: " ",
            firstCharacter: "h"
        )
        XCTAssertTrue(advances.contains { atSessionStart.matchesTypingTarget(atBoundary, expectedCaretAdvance: $0) })
    }

    func test_typingTarget_stillAcceptsSessionCaretSampledAfterTheFirstCharacterLanded() {
        let atSessionStart = signature(caret: 1)
        let atBoundary = signature(caret: 6)
        let advances = AutoFixTargetValidator.acceptableCaretAdvances(
            source: "hjvfy",
            boundary: " ",
            firstCharacter: "h"
        )
        XCTAssertTrue(advances.contains { atSessionStart.matchesTypingTarget(atBoundary, expectedCaretAdvance: $0) })
    }

    func test_typingTarget_rejectsCaretDriftBeyondTheOneCharacterRace() {
        // The window is exactly the race, not "anything nearby".
        let atSessionStart = signature(caret: 0)
        let advances = AutoFixTargetValidator.acceptableCaretAdvances(
            source: "hjvfy",
            boundary: " ",
            firstCharacter: "h"
        )
        for drifted in [4, 7, 12] {
            let atBoundary = signature(caret: drifted)
            XCTAssertFalse(
                advances.contains { atSessionStart.matchesTypingTarget(atBoundary, expectedCaretAdvance: $0) },
                "caret at \(drifted) is not explainable by the race"
            )
        }
    }

    func test_identityIgnoringPosition_acceptsACaretThatMovedOnWhileTypingContinued() {
        // What a deferred fix sees: same field, caret far past the boundary because
        // the user kept typing through the 0.3 s grace period.
        XCTAssertTrue(signature(caret: 6).matchesTypingTargetIgnoringPosition(signature(caret: 31)))
    }

    func test_identityIgnoringPosition_stillRejectsADifferentField() {
        let composer = signature(caret: 6, identifier: "composer")
        let search = signature(caret: 6, identifier: "search")
        XCTAssertFalse(composer.matchesTypingTargetIgnoringPosition(search))

        let otherProcess = FocusedElementSignature(
            pid: 999,
            role: "AXTextArea",
            subrole: nil,
            windowTitleHash: 1,
            elementIdentifier: "editor",
            frameHash: 1,
            selectedRangeLocation: 6
        )
        XCTAssertFalse(signature(caret: 6).matchesTypingTargetIgnoringPosition(otherProcess))
    }

    // MARK: - Caret restoration

    func test_restoredCaret_keepsTheUserWhereTheyAreTypingWhenLengthsDiffer() {
        // "hjvfy" (5) at 10..15 became "роман" (5) -> no shift; then a longer one.
        let source = AXTextRange(location: 10, length: 5)
        XCTAssertEqual(
            AutoFixTargetValidator.restoredCaretLocation(
                liveCaret: 22, sourceRange: source, replacementUTF16Length: 5, boundaryUTF16Length: 1
            ),
            22
        )
        XCTAssertEqual(
            AutoFixTargetValidator.restoredCaretLocation(
                liveCaret: 22, sourceRange: source, replacementUTF16Length: 8, boundaryUTF16Length: 1
            ),
            25,
            "caret shifts by exactly how much the token grew"
        )
        XCTAssertEqual(
            AutoFixTargetValidator.restoredCaretLocation(
                liveCaret: 22, sourceRange: source, replacementUTF16Length: 3, boundaryUTF16Length: 1
            ),
            20,
            "and by how much it shrank"
        )
    }

    func test_restoredCaret_fallsBackToJustPastTheTokenWithoutALiveCaret() {
        let source = AXTextRange(location: 10, length: 5)
        XCTAssertEqual(
            AutoFixTargetValidator.restoredCaretLocation(
                liveCaret: nil, sourceRange: source, replacementUTF16Length: 5, boundaryUTF16Length: 1
            ),
            16
        )
        XCTAssertEqual(
            AutoFixTargetValidator.restoredCaretLocation(
                liveCaret: 12, sourceRange: source, replacementUTF16Length: 5, boundaryUTF16Length: 1
            ),
            16,
            "a caret inside the token cannot be shifted; park it after the replacement"
        )
    }

    // MARK: - Editing guard bypass: the word provably stands alone

    func test_standsAlone_whenTheFieldHoldsNothingElse() {
        // The first word of a fresh chat message — the case the click guard
        // was eating wholesale.
        XCTAssertTrue(AutoFixTargetValidator.standsAloneInValue(
            source: "nj", boundary: " ", value: "nj "
        ))
    }

    func test_standsAlone_whenTheWordOpensTheField() {
        XCTAssertTrue(AutoFixTargetValidator.standsAloneInValue(
            source: "nj", boundary: " ", value: "nj і далі чернетка"
        ))
    }

    func test_standsAlone_whenAppendedAfterWhitespace() {
        XCTAssertTrue(AutoFixTargetValidator.standsAloneInValue(
            source: "yt", boundary: " ", value: "чернетка yt "
        ))
        XCTAssertTrue(AutoFixTargetValidator.standsAloneInValue(
            source: "nj", boundary: "\r", value: "рядок\nnj\n"
        ), "Enter boundary reads back as newline; the previous line break separates")
    }

    func test_standsAlone_rejectsAWordGluedToExistingText() {
        // Click landed inside "к|"; typing "nj" produced "кnj" — exactly what
        // the guard exists to protect.
        XCTAssertFalse(AutoFixTargetValidator.standsAloneInValue(
            source: "nj", boundary: " ", value: "кnj "
        ))
        XCTAssertFalse(AutoFixTargetValidator.standsAloneInValue(
            source: "nj", boundary: " ", value: "текст nj усередині"
        ), "mid-field cannot be proven from the ends")
        XCTAssertFalse(AutoFixTargetValidator.standsAloneInValue(
            source: "nj", boundary: " ", value: "зовсім інше"
        ))
    }

    // MARK: - Retroactive anchor: locating an old run by content

    func test_uniqueOccurrence_findsTheRunTheUserTypedPast() {
        XCTAssertEqual(
            AutoFixTargetValidator.uniqueOccurrenceStart(of: "nj ljhtxs ", in: "nj ljhtxs і далі текст"),
            0
        )
        XCTAssertEqual(
            AutoFixTargetValidator.uniqueOccurrenceStart(of: "cksd ", in: "yt vf. cksd "),
            7
        )
    }

    func test_uniqueOccurrence_isUTF16ForComposedText() {
        // "🙂" is 2 UTF-16 units; a character-based index would be off by one.
        XCTAssertEqual(
            AutoFixTargetValidator.uniqueOccurrenceStart(of: "ghbdsn ", in: "🙂 ghbdsn "),
            3
        )
    }

    func test_uniqueOccurrence_refusesZeroAndMultipleMatches() {
        XCTAssertNil(
            AutoFixTargetValidator.uniqueOccurrenceStart(of: "ghbdsn ", in: "текст без рану"),
            "the run is gone — sent or self-corrected"
        )
        XCTAssertNil(
            AutoFixTargetValidator.uniqueOccurrenceStart(of: "lj ", in: "lj текст lj далі"),
            "two matches — the edit could land on text the user never typed"
        )
        XCTAssertNil(AutoFixTargetValidator.uniqueOccurrenceStart(of: "", in: "текст"))
        XCTAssertNil(AutoFixTargetValidator.uniqueOccurrenceStart(of: "довший за поле", in: "поле"))
    }

    // MARK: - The blind fallback still needs a frozen caret

    private func anchor(sourceRange: AXTextRange?, allowsKeyboardFallback: Bool) -> TextReplacementAnchor {
        TextReplacementAnchor(
            targetPID: 100,
            bundleID: "com.example.editor",
            focusedElementIdentity: signature(caret: 9).stableIdentity,
            sourceRange: sourceRange,
            boundaryUTF16Length: 1,
            caretAfterBoundary: 9,
            expectedSource: "hjvfy",
            allowsKeyboardFallback: allowsKeyboardFallback
        )
    }

    func test_frozenCaret_isNotRequiredWhenTheCallerReadsTheRangeBack() {
        XCTAssertFalse(
            AutoFixTargetValidator.requiresFrozenCaret(
                anchor: anchor(sourceRange: AXTextRange(location: 3, length: 5), allowsKeyboardFallback: false),
                allowsStaleCaret: true
            ),
            "the readback at the exact range is stronger evidence than caret position"
        )
    }

    func test_frozenCaret_isRequiredForTheBlindFallbackEvenWhenTheAnchorCarriesARange() {
        // captureReplacementAnchor builds the fallback anchor from the caret range it
        // could not read back, so `sourceRange` is populated on a path that never uses
        // it. Keying the exemption off the range alone let the blind Delete run against
        // a caret that had moved on.
        XCTAssertTrue(
            AutoFixTargetValidator.requiresFrozenCaret(
                anchor: anchor(sourceRange: AXTextRange(location: 3, length: 5), allowsKeyboardFallback: true),
                allowsStaleCaret: false
            )
        )
    }

    func test_frozenCaret_isRequiredWhenThereIsNoRangeToReadBack() {
        for allowsStaleCaret in [true, false] {
            XCTAssertTrue(
                AutoFixTargetValidator.requiresFrozenCaret(
                    anchor: anchor(sourceRange: nil, allowsKeyboardFallback: true),
                    allowsStaleCaret: allowsStaleCaret
                ),
                "nothing to read back, so the caret is the only anchor there is"
            )
        }
    }

    private func signature(caret: Int, identifier: String = "editor") -> FocusedElementSignature {
        FocusedElementSignature(
            pid: 100,
            role: "AXTextArea",
            subrole: nil,
            windowTitleHash: 42,
            elementIdentifier: identifier,
            frameHash: 7,
            selectedRangeLocation: caret
        )
    }

    func test_valueSuffixRange_anchorsTheTokenTypedAtTheEndOfTheField() throws {
        let anchor = try XCTUnwrap(AutoFixTargetValidator.valueSuffixRange(
            source: "ddtltyyz",
            boundary: " ",
            in: "gjvbkrf ddtltyyz "
        ))
        XCTAssertEqual(anchor.sourceRange, AXTextRange(location: 8, length: 8))
        XCTAssertEqual(anchor.caretAfterBoundary, 17, "caret belongs after the untouched boundary")
        XCTAssertEqual(
            AutoFixTargetValidator.substring(for: anchor.sourceRange, in: "gjvbkrf ddtltyyz "),
            "ddtltyyz"
        )
    }

    func test_valueSuffixRange_ignoresAnEarlierCopyOfTheSameToken() {
        // "то" appears twice; only the trailing one is the token just typed, and
        // anchoring to the earlier copy would edit text the user never touched.
        let anchor = AutoFixTargetValidator.valueSuffixRange(
            source: "nj",
            boundary: " ",
            in: "nj hj,bvj nj "
        )
        XCTAssertEqual(anchor?.sourceRange, AXTextRange(location: 10, length: 2))
    }

    func test_valueSuffixRange_refusesWhenTheTokenIsNotAtTheEnd() {
        XCTAssertNil(AutoFixTargetValidator.valueSuffixRange(
            source: "ddtltyyz",
            boundary: " ",
            in: "ddtltyyz nj oj"
        ))
    }

    func test_valueSuffixRange_refusesWithoutABoundaryToLeaveUntouched() {
        XCTAssertNil(AutoFixTargetValidator.valueSuffixRange(
            source: "ddtltyyz",
            boundary: "",
            in: "gjvbkrf ddtltyyz"
        ))
    }

    func test_valueSuffixRange_usesUTF16ForComposedText() throws {
        let value = "ab🇺🇦é "
        let anchor = try XCTUnwrap(AutoFixTargetValidator.valueSuffixRange(
            source: "ab🇺🇦é",
            boundary: " ",
            in: value
        ))
        XCTAssertEqual(anchor.sourceRange, AXTextRange(location: 0, length: "ab🇺🇦é".utf16.count))
        XCTAssertEqual(anchor.caretAfterBoundary, value.utf16.count)
        XCTAssertGreaterThan("ab🇺🇦é".utf16.count, "ab🇺🇦é".count, "test string must actually differ")
    }

    func test_stable_identity_ignores_caret_location() {
        let first = FocusedElementSignature(
            pid: 100,
            role: "AXTextArea",
            subrole: nil,
            windowTitleHash: 42,
            elementIdentifier: "editor",
            frameHash: 7,
            selectedRangeLocation: 10
        )

        let second = FocusedElementSignature(
            pid: 100,
            role: "AXTextArea",
            subrole: nil,
            windowTitleHash: 42,
            elementIdentifier: "editor",
            frameHash: 7,
            selectedRangeLocation: 15
        )

        XCTAssertEqual(first.stableIdentity, second.stableIdentity)
    }

    func test_stable_identity_changes_when_frame_changes() {
        let first = FocusedElementSignature(
            pid: 100,
            role: "AXTextField",
            subrole: nil,
            windowTitleHash: 42,
            elementIdentifier: "search",
            frameHash: 7,
            selectedRangeLocation: 1
        )

        let second = FocusedElementSignature(
            pid: 100,
            role: "AXTextField",
            subrole: nil,
            windowTitleHash: 42,
            elementIdentifier: "search",
            frameHash: 8,
            selectedRangeLocation: 1
        )

        XCTAssertNotEqual(first.stableIdentity, second.stableIdentity)
    }

    func test_typingTargetIdentity_ignoresDynamicWindowTitleAndFrameForStableIdentifier() {
        let first = FocusedElementSignature(
            pid: 100,
            role: "AXTextField",
            subrole: nil,
            windowTitleHash: 42,
            elementIdentifier: "search",
            frameHash: 7,
            selectedRangeLocation: 1
        )

        let second = FocusedElementSignature(
            pid: 100,
            role: "AXTextField",
            subrole: nil,
            windowTitleHash: 99,
            elementIdentifier: "search",
            frameHash: 8,
            selectedRangeLocation: 20
        )

        XCTAssertTrue(first.matchesTypingTarget(second, expectedCaretAdvance: 19))
    }

    func test_typingTargetIdentity_rejectsDifferentIdentifiers() {
        let first = FocusedElementSignature(
            pid: 100,
            role: "AXTextField",
            subrole: nil,
            windowTitleHash: 42,
            elementIdentifier: "search",
            frameHash: 7,
            selectedRangeLocation: 1
        )

        let second = FocusedElementSignature(
            pid: 100,
            role: "AXTextField",
            subrole: nil,
            windowTitleHash: 42,
            elementIdentifier: "other-field",
            frameHash: 7,
            selectedRangeLocation: 1
        )

        XCTAssertFalse(first.matchesTypingTarget(second, expectedCaretAdvance: 0))
    }

    func test_typingTargetIdentity_rejectsUnexpectedCaretForSameIdentifier() {
        let first = FocusedElementSignature(
            pid: 100,
            role: "AXTextField",
            subrole: nil,
            windowTitleHash: 42,
            elementIdentifier: "search",
            frameHash: 7,
            selectedRangeLocation: 1
        )

        let second = FocusedElementSignature(
            pid: 100,
            role: "AXTextField",
            subrole: nil,
            windowTitleHash: 99,
            elementIdentifier: "search",
            frameHash: 8,
            selectedRangeLocation: 50
        )

        XCTAssertFalse(first.matchesTypingTarget(second, expectedCaretAdvance: 19))
    }

    func test_typingTargetIdentity_allowsDynamicGeometryWithoutIdentifierWhenCaretMatches() {
        let first = FocusedElementSignature(
            pid: 100,
            role: "AXTextField",
            subrole: nil,
            windowTitleHash: 42,
            elementIdentifier: nil,
            frameHash: 7,
            selectedRangeLocation: 1
        )

        let second = FocusedElementSignature(
            pid: 100,
            role: "AXTextField",
            subrole: nil,
            windowTitleHash: 99,
            elementIdentifier: nil,
            frameHash: 8,
            selectedRangeLocation: 20
        )

        XCTAssertTrue(first.matchesTypingTarget(second, expectedCaretAdvance: 19))
    }

    func test_typingTargetIdentity_rejectsDynamicGeometryWhenCaretIsUnavailable() {
        let first = FocusedElementSignature(
            pid: 100,
            role: "AXTextField",
            subrole: nil,
            windowTitleHash: 42,
            elementIdentifier: "search",
            frameHash: 7,
            selectedRangeLocation: nil
        )

        let second = FocusedElementSignature(
            pid: 100,
            role: "AXTextField",
            subrole: nil,
            windowTitleHash: 99,
            elementIdentifier: "search",
            frameHash: 8,
            selectedRangeLocation: nil
        )

        XCTAssertFalse(first.matchesTypingTarget(second, expectedCaretAdvance: 19))
    }

    func test_typingTargetIdentity_acceptsRecreatedAXProxyAtSameFrame() {
        let first = FocusedElementSignature(
            pid: 100,
            role: "AXTextField",
            subrole: nil,
            windowTitleHash: 42,
            elementIdentifier: "search",
            frameHash: 7,
            selectedRangeLocation: 1,
            elementIdentity: AXUIElementCreateApplication(100)
        )

        let second = FocusedElementSignature(
            pid: 100,
            role: "AXTextField",
            subrole: nil,
            windowTitleHash: 99,
            elementIdentifier: "search",
            frameHash: 7,
            selectedRangeLocation: 20,
            elementIdentity: AXUIElementCreateApplication(101)
        )

        XCTAssertTrue(first.matchesTypingTarget(second, expectedCaretAdvance: 19))
    }

    func test_typingTargetIdentity_acceptsRecreatedAXProxyAtDifferentFrameWhenCaretMatches() {
        let first = FocusedElementSignature(
            pid: 100,
            role: "AXTextField",
            subrole: nil,
            windowTitleHash: 42,
            elementIdentifier: "search",
            frameHash: 7,
            selectedRangeLocation: 1,
            elementIdentity: AXUIElementCreateApplication(100)
        )

        let second = FocusedElementSignature(
            pid: 100,
            role: "AXTextField",
            subrole: nil,
            windowTitleHash: 99,
            elementIdentifier: "search",
            frameHash: 8,
            selectedRangeLocation: 20,
            elementIdentity: AXUIElementCreateApplication(101)
        )

        XCTAssertTrue(first.matchesTypingTarget(second, expectedCaretAdvance: 19))
    }

    func test_utf16Substring_readsExactRangeFromFullAXValue() {
        XCTAssertEqual(
            AutoFixTargetValidator.substring(
                for: AXTextRange(location: 8, length: 9),
                in: "prefix: іудусещкі "
            ),
            "іудусещкі"
        )
    }

    func test_utf16Substring_rejectsOutOfBoundsRange() {
        XCTAssertNil(
            AutoFixTargetValidator.substring(
                for: AXTextRange(location: 20, length: 1),
                in: "short"
            )
        )
    }

    // MARK: - Release-candidate regressions

    func test_standsAlone_rejectsGluedCopyEvenWhenTheFieldOpensWithTheWord() {
        // The field opens with "nj ", but the copy just typed is glued: "кnj ".
        // Nothing says which copy is the typed one, so the guard must hold.
        XCTAssertFalse(AutoFixTargetValidator.standsAloneInValue(
            source: "nj", boundary: " ", value: "nj щось кnj "
        ))
    }

    func test_standsAlone_acceptsRepeatedWordWhenEveryCopyIsAligned() {
        XCTAssertTrue(AutoFixTargetValidator.standsAloneInValue(
            source: "nj", boundary: " ", value: "nj щось nj "
        ))
    }

    func test_wordStart_requiresFieldStartOrWhitespace() {
        XCTAssertTrue(AutoFixTargetValidator.isWordStart(at: 0, in: "nj "))
        XCTAssertTrue(AutoFixTargetValidator.isWordStart(at: 4, in: "abc nj "))
        XCTAssertFalse(AutoFixTargetValidator.isWordStart(at: 1, in: "xnj "))
        XCTAssertFalse(AutoFixTargetValidator.isWordStart(at: 99, in: "short"))
    }

    func test_retroactiveMatch_uniqueButGluedOccurrenceIsNotAWord() {
        // The chip's "nj " is gone; "xnj " is now the only occurrence. It is the
        // tail of another word, so the chip must not rewrite it.
        let value = "текст xnj "
        let start = AutoFixTargetValidator.uniqueOccurrenceStart(of: "nj ", in: value)
        XCTAssertEqual(start, 7)
        XCTAssertFalse(AutoFixTargetValidator.isWordStart(at: start!, in: value))
    }

    func test_keyboardFallbackAnchorDoesNotSurviveLaterTyping() {
        // Deferred chip / reopened proposal: the user has typed since, and a blind
        // Delete burst at the current caret would eat that new text.
        XCTAssertFalse(anchor(sourceRange: nil, allowsKeyboardFallback: true).survivesLaterTyping)
        XCTAssertTrue(anchor(
            sourceRange: AXTextRange(location: 3, length: 5),
            allowsKeyboardFallback: false
        ).survivesLaterTyping)
    }

    func test_sameWindow_rejectsAnotherWindowOfTheSameApp() {
        func identity(pid: pid_t, title: Int?) -> FocusedElementSignature.StableIdentity {
            .init(pid: pid, role: "AXTextArea", subrole: nil, windowTitleHash: title,
                  elementIdentifier: nil, frameHash: nil)
        }
        XCTAssertTrue(AutoFixTargetValidator.isSameWindow(identity(pid: 1, title: 7), identity(pid: 1, title: 7)))
        XCTAssertFalse(AutoFixTargetValidator.isSameWindow(identity(pid: 1, title: 7), identity(pid: 1, title: 8)))
        XCTAssertFalse(AutoFixTargetValidator.isSameWindow(identity(pid: 1, title: 7), identity(pid: 2, title: 7)))
        XCTAssertTrue(AutoFixTargetValidator.isSameWindow(identity(pid: 1, title: nil), identity(pid: 1, title: 8)),
                      "no title to compare: fall back to the process")
    }

    func testStandsAloneAtCaretProvesWordInMiddleOfField() {
        // Reply typed mid-field: not at either edge, but the caret pins it.
        let value = "перший рядок\nnj \nпідпис"
        XCTAssertFalse(AutoFixTargetValidator.standsAloneInValue(source: "nj", boundary: " ", value: value))
        XCTAssertTrue(AutoFixTargetValidator.standsAloneAtCaret(source: "nj", boundary: " ", value: value, caret: 16))
        XCTAssertNil(AutoFixTargetValidator.standsAloneRejection(source: "nj", boundary: " ", value: value, caret: 16))
    }

    func testStandsAloneAtCaretAcceptsComposerTrailingNewline() {
        // Web composers keep a stray newline after the caret.
        XCTAssertTrue(AutoFixTargetValidator.standsAloneAtCaret(
            source: "ghbdsn", boundary: " ", value: "ghbdsn \n", caret: 7))
        // Boundary not rendered yet: only whitespace may follow the caret.
        XCTAssertTrue(AutoFixTargetValidator.standsAloneAtCaret(
            source: "ghbdsn", boundary: " ", value: "ghbdsn\n", caret: 6))
        XCTAssertFalse(AutoFixTargetValidator.standsAloneAtCaret(
            source: "ghbdsn", boundary: " ", value: "ghbdsnхвіст", caret: 6))
    }

    func testStandsAloneAtCaretRejectsWordGluedToExistingText() {
        // "к|" + "nj " — the exact corruption the editing guard exists for.
        let value = "щось кnj далі"
        XCTAssertFalse(AutoFixTargetValidator.standsAloneAtCaret(source: "nj", boundary: " ", value: value, caret: 9))
        XCTAssertEqual(
            AutoFixTargetValidator.standsAloneRejection(source: "nj", boundary: " ", value: value, caret: 9),
            "glued_to_text")
        // Backspaced into "wor", retyped "rd": the buffer is a fragment.
        XCTAssertNotNil(AutoFixTargetValidator.standsAloneRejection(
            source: "rd", boundary: " ", value: "hello word ", caret: 11))
        XCTAssertEqual(
            AutoFixTargetValidator.standsAloneRejection(source: "nj", boundary: " ", value: "зовсім інше", caret: 3),
            "word_not_in_value")
    }

    func testMismatchDetailNamesTheFirstDifferingComponent() {
        func signature(title: Int? = 1, frame: Int? = 1, caret: Int? = nil, role: String = "AXTextArea") -> FocusedElementSignature {
            FocusedElementSignature(pid: 1, role: role, subrole: nil, windowTitleHash: title,
                                    elementIdentifier: nil, frameHash: frame, selectedRangeLocation: caret)
        }
        XCTAssertEqual(signature().mismatchDetail(signature(title: 2)), "window_title")
        XCTAssertEqual(signature().mismatchDetail(signature(frame: 2)), "frame")
        XCTAssertEqual(signature(caret: 3).mismatchDetail(signature(caret: 9)), "caret")
        XCTAssertEqual(signature(caret: 3).mismatchDetail(signature()), "caret_availability")
        XCTAssertEqual(signature().mismatchDetail(signature(role: "AXTextField")), "role")
    }
}
