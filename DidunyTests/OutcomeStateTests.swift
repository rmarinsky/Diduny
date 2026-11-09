import Foundation
import Testing
@testable import Diduny

@Suite("Command panel outcome after Stop")
struct OutcomeStateTests {
    @Test func outcomeReplacesTheLiveViewWithoutASlide() {
        #expect(!EdgeCommandExpandedView.ContentState.outcome.slidesIn)
        #expect(!EdgeCommandExpandedView.ContentState.live.slidesIn)
        #expect(EdgeCommandExpandedView.ContentState.home.slidesIn)
    }

    @Test func autoHidesOnlyAfterAPaste() {
        #expect(DictationOverlayController.outcomeAutoHideDelay(delivery: .pasted) == 0.8)
        #expect(DictationOverlayController.outcomeAutoHideDelay(delivery: .copied) == nil)
    }

    @Test func onlyRestoringFromTheTabMorphs() {
        #expect(EdgeCommandPanelLiveEntrance.make(alreadyLive: false, restoredByUser: false) == .immediate)
        #expect(EdgeCommandPanelLiveEntrance.make(alreadyLive: false, restoredByUser: true) == .morph)
        #expect(EdgeCommandPanelLiveEntrance.make(alreadyLive: true, restoredByUser: false) == .update)
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

    // T2-ST-02, Roman 2026-11-09
    @Test func titleSaysWhatHappened() {
        func title(_ flow: EdgeCommandOutcome.Flow, _ delivery: EdgeCommandOutcome.Delivery) -> String {
            EdgeCommandOutcome(flow: flow, durationSeconds: 7, delivery: delivery).title
        }
        #expect(title(.dictation, .pasted) == "Dictated and pasted")
        #expect(title(.dictationTranslation(languageName: "English"), .pasted) == "Translated and pasted")
        #expect(title(.meeting, .pasted) == "Meeting ended and pasted")
        #expect(title(.meetingTranslation(pair: "EN ↔ UK"), .pasted) == "Meeting ended and pasted")
        #expect(title(.dictation, .copied) == "Copied")
        #expect(title(.dictationTranslation(languageName: "English"), .copied) == "Copied")
        #expect(title(.meeting, .copied) == "Meeting saved")
    }

    @MainActor @Test func theAppPastesThroughTheInstanceTheOutcomeReads() {
        #expect(AppDelegate().clipboardService === ClipboardService.shared)
    }

    @Test func deliveryUsesOnlyAPasteOfThisRecording() {
        let stop = Date(timeIntervalSince1970: 1000)
        let fresh = stop.addingTimeInterval(1)
        let stale = stop.addingTimeInterval(-60)
        #expect(DictationOverlayController.delivery(autoPaste: true, lastPaste: fresh, stoppedAt: stop) == .pasted)
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

@Suite("Settings and panel details from Roman's DEV feedback")
struct DevFeedbackDetailTests {
    @Test func normalSpeechReachesWellUpTheMeter() {
        func level(db: Float) -> Float { (db + 60) / 60 }
        #expect(LiveAudioMeter.litBars(level(db: -58)) == 0)
        #expect(LiveAudioMeter.litBars(level(db: -30)) >= 4)
        #expect(LiveAudioMeter.displayLevel(level(db: -20)) > 0.99)
        #expect(LiveAudioMeter.litBars(level(db: 0)) == 5)
    }

    /// Fixed columns plus flexible columns fill the row exactly, so every chevron is at the same x.
    @Test(arguments: [713.5, 840] as [CGFloat])
    func modeRowColumnsFillTheRow(total: CGFloat) {
        let widths = ModesGrid.flexibleWidths(total: total)
        let sum = ModesGrid.modeColumn + widths.engine + widths.second + ModesGrid.shortcutColumn
            + DS.Size.expander + ModesGrid.gap * 4
        #expect(abs(sum - total) < 0.01)
    }

    /// Roman's 1.5x (DEV feedback) still holds: the old 28 pt badge is now the 42 pt logo disc. The stop animation
    /// replaced the old burst room (44 pt layout) with pulse room, so the panel size is disc plus margins.
    @MainActor @Test func inPlaceBadgeIsOneAndAHalfTimesBigger() {
        #expect(PasteMarkPlan.disc == 28 * 1.5)
        let side = PasteMarkPlan.disc + 2 * PasteMarkPlan.panelMargin
        #expect(InplaceTranslationFeedbackController.badgeSize == CGSize(width: side, height: side))
    }
}
