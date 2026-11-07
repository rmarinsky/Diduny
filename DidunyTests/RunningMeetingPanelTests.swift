@testable import Diduny
import Testing

/// The live meeting panels show the running session, not Settings > Modes (WP-30, WP-31, WP-32 fixes).
@MainActor
struct RunningMeetingPanelTests {
    @Test("Running segment from the session: Record only, Cloud, live on this Mac, audio only")
    func runningSegment() {
        #expect(RunningMeetingSession.segment(recordOnly: true, cloudMode: true, localPreview: true) == .recordOnly)
        #expect(RunningMeetingSession.segment(recordOnly: false, cloudMode: true, localPreview: false) == .cloud)
        #expect(RunningMeetingSession.segment(recordOnly: false, cloudMode: false, localPreview: true) == .thisMac)
        #expect(RunningMeetingSession.segment(recordOnly: false, cloudMode: false, localPreview: false) == .recordOnly)
    }

    @Test("Running engine: own live engine on Cloud, Whisper live on this Mac, the after-Stop pick in Record only")
    func runningEngine() {
        #expect(RunningMeetingSession.engine(segment: .cloud, ownLiveEngine: nil, afterStopEngine: nil) == .didunyCloud)
        #expect(RunningMeetingSession.engine(segment: .cloud, ownLiveEngine: .elevenLabs, afterStopEngine: nil) == .elevenLabs)
        #expect(RunningMeetingSession.engine(segment: .thisMac, ownLiveEngine: nil, afterStopEngine: nil) == .whisper)
        #expect(RunningMeetingSession.engine(segment: .recordOnly, ownLiveEngine: nil, afterStopEngine: "parakeet-v3") == .parakeet)
        #expect(RunningMeetingSession.engine(segment: .recordOnly, ownLiveEngine: nil, afterStopEngine: nil) == .whisper)
    }

    @Test("Until WP-63: only the running segment is enabled and the engine field is static")
    func switchingLocked() {
        let store = LiveDictationOverlayStore()
        store.showRunningMeeting(segment: .recordOnly, engine: .whisper)
        let state = store.meetingPanelState
        #expect(store.meetingSwitchingLocked)
        #expect(state.segment == .recordOnly)
        #expect(state.engine == .whisper)
        #expect(state.segments.filter(\.isEnabled).map(\.id) == [.recordOnly])
        #expect(state.isFieldStatic)
        #expect(!state.showsUseCloudLink)
    }

    @Test("Translate meeting on Cloud offers only Diduny Cloud, never a local engine")
    func translateMeetingOffersRunningEngineOnly() throws {
        let store = LiveDictationOverlayStore()
        store.showRunningMeetingTranslation(engine: .didunyCloud)
        let model = try #require(store.translateMeetingPanelModel)
        #expect(model.engine.caps.id == .didunyCloud)
        let offered = model.engines.map(\.caps.id)
        #expect(offered == [.didunyCloud])
        #expect(!offered.contains(.whisper))
    }

    @Test("Record only calm box offers Turn on live transcript; other segments do not")
    func turnOnLiveTranscript() {
        let store = LiveDictationOverlayStore()
        var calls = 0
        store.onTurnOnLiveTranscript = { calls += 1 }
        store.showRunningMeeting(segment: .recordOnly, engine: .whisper)
        store.meetingTurnOnLiveTranscript?()
        #expect(calls == 1)
        store.showRunningMeeting(segment: .cloud, engine: .didunyCloud)
        #expect(store.meetingTurnOnLiveTranscript == nil)
    }
}
