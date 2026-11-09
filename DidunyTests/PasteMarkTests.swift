import AppKit
import Testing
@testable import Diduny

@Suite("Logo after Stop (stop animation)")
struct PasteMarkTests {
    @Test func meetingsAlwaysUseThePanelHeader() {
        #expect(PasteMarkPlan.surface(isMeeting: true, pasted: false, caretKnown: true) == .panelHeader)
        #expect(PasteMarkPlan.surface(isMeeting: true, pasted: true, caretKnown: true) == .panelHeader)
    }

    @Test func dictationPlaysAtTheCaretOnlyWhenItIsKnown() {
        #expect(PasteMarkPlan.surface(isMeeting: false, pasted: true, caretKnown: true) == .caret)
        #expect(PasteMarkPlan.surface(isMeeting: false, pasted: true, caretKnown: false) == .panelHeader)
        #expect(PasteMarkPlan.surface(isMeeting: false, pasted: false, caretKnown: true) == .none)
    }

    @Test func timelineMatchesTheReadme() {
        let timeline = PasteMarkPlan.timeline(reduceMotion: false)
        #expect(timeline.appear == 0.18)
        #expect(timeline.ringClose == 0.20)
        #expect(timeline.glide == 0.22)
        #expect(timeline.pulseStart == 0.22)
        #expect(timeline.pulse == 0.40)
        #expect(timeline.fadeStart == 0.68)
        #expect(abs(timeline.total - 0.83) < 0.0001)
    }

    @Test func reduceMotionHasNoGlideOrPulse() {
        let timeline = PasteMarkPlan.timeline(reduceMotion: true)
        #expect(timeline.glide == 0)
        #expect(timeline.pulse == 0)
        #expect(timeline.ringClose == 0.12)
        #expect(timeline.fade == 0.15)
        #expect(timeline.total <= PasteMarkPlan.timeline(reduceMotion: false).total)
    }

    @Test func headerLogoPulsesOnAppearOnlyAsTheOnlySignal() {
        #expect(PasteMarkPlan.headerPulsesOnAppear(isMeeting: true, transcriptReady: true))
        #expect(!PasteMarkPlan.headerPulsesOnAppear(isMeeting: true, transcriptReady: false))
        #expect(PasteMarkPlan.headerPulsesOnAppear(isMeeting: false, transcriptReady: false))
    }

    // Roman, 2026-11-09: no result window after a dictation or translation.
    @Test func dictationEndsWithoutAResultWindow() {
        #expect(PasteMarkPlan.dictationEnd(autoPaste: true, pasted: true, caretKnown: true) == .closeNow)
        #expect(PasteMarkPlan.dictationEnd(autoPaste: true, pasted: true, caretKnown: false) == .headerLogo)
        #expect(PasteMarkPlan.dictationEnd(autoPaste: false, pasted: false, caretKnown: false) == .headerLogo)
        #expect(PasteMarkPlan.headerLogoSeconds == 1.5)
    }

    @Test func aFailedPasteKeepsTheCopiedOutcome() {
        #expect(PasteMarkPlan.dictationEnd(autoPaste: true, pasted: false, caretKnown: true) == .copiedOutcome)
    }

    @Test func typingClearsButCommandChordsDoNot() {
        #expect(PasteMarkPlan.keyDownClears(modifiers: []))
        #expect(PasteMarkPlan.keyDownClears(modifiers: .shift))
        #expect(!PasteMarkPlan.keyDownClears(modifiers: .command))
        #expect(!PasteMarkPlan.keyDownClears(modifiers: [.command, .shift]))
    }

    @Test func phasesFollowTheFlow() {
        var phase = PasteMarkPlan.next(.idle, .finalizing)
        #expect(phase == .locating)
        phase = PasteMarkPlan.next(phase, .caretFound)
        #expect(phase == .waiting)
        phase = PasteMarkPlan.next(phase, .pasted)
        #expect(phase == .landing)
        #expect(PasteMarkPlan.next(phase, .finished) == .idle)
        #expect(PasteMarkPlan.next(.locating, .caretMissing) == .idle)
        #expect(PasteMarkPlan.next(.locating, .pasted) == .idle)
    }

    @Test func interruptionsClearEveryPhase() {
        for phase in [PasteMarkPlan.Phase.locating, .waiting, .landing] {
            #expect(PasteMarkPlan.next(phase, .typed) == .idle)
            #expect(PasteMarkPlan.next(phase, .newRecording) == .idle)
            #expect(PasteMarkPlan.next(phase, .notPasted) == .idle)
        }
        #expect(PasteMarkPlan.next(.landing, .finalizing) == .locating)
    }

    @Test func implausibleCaretRectsFallBackToThePanel() {
        #expect(PasteMarkPlan.plausibleCaretRect(nil) == nil)
        #expect(PasteMarkPlan.plausibleCaretRect(.zero) == nil)
        #expect(PasteMarkPlan.plausibleCaretRect(CGRect(x: 0, y: 0, width: 800, height: 600)) == nil)
        let glyph = CGRect(x: 100, y: 200, width: 8, height: 17)
        #expect(PasteMarkPlan.plausibleCaretRect(glyph) == glyph)
    }

    @Test func pollFindsTheEndOfThePastedText() async {
        let end = CaretPosition(location: 42, rect: CGRect(x: 300, y: 200, width: 8, height: 17))
        let geometry = FakeCaretGeometry(answers: [
            CaretPosition(location: 10, rect: CGRect(x: 100, y: 200, width: 8, height: 17)),
            nil,
            end
        ])
        let found = await PasteMarkPlan.pollPastedEnd(geometry: geometry, before: 10, interval: .milliseconds(1))
        #expect(found == end)
    }

    @Test func pollGivesUpWhenTheCaretNeverMoves() async {
        let still = CaretPosition(location: 10, rect: CGRect(x: 100, y: 200, width: 8, height: 17))
        let geometry = FakeCaretGeometry(answers: [still])
        let found = await PasteMarkPlan.pollPastedEnd(
            geometry: geometry, before: 10, timeout: .milliseconds(30), interval: .milliseconds(5)
        )
        #expect(found == nil)
    }
}

/// Answers in order, then repeats the last answer.
private final class FakeCaretGeometry: CaretGeometry, @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [CaretPosition?]

    init(answers: [CaretPosition?]) {
        self.answers = answers
    }

    func caret() -> CaretPosition? {
        lock.lock()
        defer { lock.unlock() }
        return answers.count > 1 ? answers.removeFirst() : answers.first ?? nil
    }
}

@Suite("Logo opens into the live panel")
struct PanelLogoEntranceTests {
    @Test func startsOverTheHeaderIconAndStaysQuick() {
        let bounds = CGRect(x: 0, y: 0, width: 300, height: 200)
        let disc = EdgeCommandPanelLogoEntrance.startDisc(in: bounds)
        #expect(disc == CGRect(x: DS.Panel.padding, y: 200 - DS.Panel.padding - 28, width: 28, height: 28))
        #expect(EdgeCommandPanelLogoEntrance.duration <= 0.24)
        #expect(EdgeCommandPanelLogoEntrance.logoFade < EdgeCommandPanelLogoEntrance.duration)
    }
}
