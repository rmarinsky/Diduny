import Foundation
import Testing
@testable import Diduny

@Suite("Command panel outcome after Stop")
struct OutcomeStateTests {
    @Test func outcomeReplacesTheLiveViewWithoutASlide() {
        #expect(!EdgeCommandExpandedView.ContentState.outcome.slidesIn)
        #expect(EdgeCommandExpandedView.ContentState.live.slidesIn)
        #expect(EdgeCommandExpandedView.ContentState.home.slidesIn)
    }

    @Test func autoHidesOnlyWithAutoPaste() {
        #expect(DictationOverlayController.outcomeAutoHideDelay(autoPaste: true) == 0.8)
        #expect(DictationOverlayController.outcomeAutoHideDelay(autoPaste: false) == nil)
    }

    // T2-ST-01
    @Test func dictationSubtitle() {
        let outcome = EdgeCommandOutcome(flow: .dictation, durationSeconds: 7)
        #expect(outcome.subtitle(transcript: .ready) == "7 s · also in Recordings")
    }

    @Test func dictationTranslationSubtitle() {
        let outcome = EdgeCommandOutcome(flow: .dictationTranslation(languageName: "English"), durationSeconds: 7)
        #expect(outcome.subtitle(transcript: .ready) == "Translated into English · 7 s")
    }

    @Test func meetingSubtitleMakingThenReady() {
        let outcome = EdgeCommandOutcome(flow: .meeting, durationSeconds: 382)
        #expect(outcome.title == "Meeting saved")
        #expect(outcome.subtitle(transcript: .making(fraction: 0.2)) == "6 min 22 s · making the transcript...")
        #expect(outcome.subtitle(transcript: .ready) == "6 min 22 s · transcript ready")
    }

    @Test func translateMeetingNamesThePair() {
        let outcome = EdgeCommandOutcome(flow: .meetingTranslation(pair: "EN ↔ UK"), durationSeconds: 382)
        #expect(outcome.subtitle(transcript: .ready) == "6 min 22 s · transcript ready, translated EN ↔ UK")
        let oneWay = EdgeCommandOutcome(flow: .meetingTranslation(pair: "→ UK"), durationSeconds: 382)
        #expect(oneWay.subtitle(transcript: .ready) == "6 min 22 s · transcript ready, translated → UK")
    }

    @Test func shortMeetingDuration() {
        #expect(EdgeCommandOutcome.meetingDuration(42) == "42 s")
    }

    // T2-ST-02 and default 8
    @Test func titleNamesThePasteTarget() {
        #expect(EdgeCommandOutcome(flow: .dictation, durationSeconds: 7, delivery: .pasted(appName: "Notes")).title == "Pasted into Notes")
        #expect(EdgeCommandOutcome(flow: .dictation, durationSeconds: 7, delivery: .pasted(appName: nil)).title == "Pasted")
        #expect(EdgeCommandOutcome(flow: .dictation, durationSeconds: 7, delivery: .copied).title == "Copied")
    }

    @Test func pasteTargetSkipsDidunyItself() {
        #expect(ClipboardService.pasteTargetName(localizedName: "Notes", bundleIdentifier: "com.apple.Notes", ownBundleIdentifier: "ua.com.rmarinsky.diduny") == "Notes")
        #expect(ClipboardService.pasteTargetName(localizedName: "Diduny", bundleIdentifier: "ua.com.rmarinsky.diduny", ownBundleIdentifier: "ua.com.rmarinsky.diduny") == nil)
        #expect(ClipboardService.pasteTargetName(localizedName: nil, bundleIdentifier: nil, ownBundleIdentifier: "x") == nil)
    }

    @Test func deliveryUsesOnlyAPasteOfThisRecording() {
        let stop = Date(timeIntervalSince1970: 1000)
        let fresh = ClipboardService.PasteRecord(appName: "Notes", at: stop.addingTimeInterval(1))
        let stale = ClipboardService.PasteRecord(appName: "Mail", at: stop.addingTimeInterval(-60))
        #expect(DictationOverlayController.delivery(autoPaste: true, lastPaste: fresh, stoppedAt: stop) == .pasted(appName: "Notes"))
        #expect(DictationOverlayController.delivery(autoPaste: true, lastPaste: stale, stoppedAt: stop) == .copied)
        #expect(DictationOverlayController.delivery(autoPaste: true, lastPaste: nil, stoppedAt: stop) == .copied)
        #expect(DictationOverlayController.delivery(autoPaste: false, lastPaste: fresh, stoppedAt: stop) == .copied)
    }

    // T2-ST-03 and default 02 Q12
    @Test func progressFollowsOnlyThisRecording() {
        let mine = UUID()
        let other = UUID()
        let progress = { (f: Double) in QueueProgress(stage: .transcribing, provider: .cloud, totalSeconds: 382, fraction: f) }
        #expect(OutcomeTranscriptState.make(recordingID: mine, isQueued: false, currentRecordingID: mine, currentProgress: progress(0.4)) == .making(fraction: 0.4))
        #expect(OutcomeTranscriptState.make(recordingID: mine, isQueued: true, currentRecordingID: other, currentProgress: progress(0.9)) == .making(fraction: 0))
    }

    @Test func readyAtOnceWhenNothingIsQueued() {
        #expect(OutcomeTranscriptState.make(recordingID: UUID(), isQueued: false, currentRecordingID: UUID(), currentProgress: nil) == .ready)
        #expect(OutcomeTranscriptState.make(recordingID: nil, isQueued: false, currentRecordingID: nil, currentProgress: nil) == .ready)
    }

    // Default 02 Q13
    @Test func dictationStopBarFillsOverOnePointFourSeconds() {
        #expect(StopProgressTiming.dictationFraction(elapsed: 0.7, textArrived: false) == 0.5)
        #expect(StopProgressTiming.dictationFraction(elapsed: 3, textArrived: false) == 1)
        #expect(StopProgressTiming.dictationFraction(elapsed: 0.1, textArrived: true) == 1)
    }

    // WP-42 fix: the outcome replaces the live view only after success, while the live view is up.
    @MainActor @Test func outcomeShownOnlyAfterSuccess() {
        let outcome = EdgeCommandOutcome(flow: .dictation, durationSeconds: 7)
        #expect(EdgeCommandOutcomeVisibility.outcome(outcome, isShowingLiveFeedback: true, phase: .pasted) == outcome)
        #expect(EdgeCommandOutcomeVisibility.outcome(outcome, isShowingLiveFeedback: true, phase: .processing) == nil)
        #expect(EdgeCommandOutcomeVisibility.outcome(outcome, isShowingLiveFeedback: false, phase: .pasted) == nil)
        #expect(EdgeCommandOutcomeVisibility.outcome(nil, isShowingLiveFeedback: true, phase: .pasted) == nil)
    }

    @MainActor @Test func translateMeetingOutcomeUsesThePair() {
        let pair = TranslationLanguagePair(languageA: "en", languageB: "uk")
        #expect(DictationOverlayController.meetingTranslationFlow(engine: .didunyCloud, pair: pair)
            == .meetingTranslation(pair: "EN ↔ UK"))
        #expect(DictationOverlayController.meetingTranslationFlow(engine: .whisper, pair: pair)
            == .meetingTranslation(pair: "→ UK"))
    }
}
