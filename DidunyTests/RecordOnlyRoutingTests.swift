@testable import Diduny
import Foundation
import Testing

/// WP-62: Record only runs its own engine after Stop; calendar meetings follow Settings › Modes (8A).
@MainActor
@Suite("Record only routing")
struct RecordOnlyRoutingTests {
    @Test("Every Record only engine produces a transcript after Stop (N4, N23)",
          arguments: [(EngineID.didunyCloud, "cloud"), (.elevenLabs, "elevenlabs-diarize"), (.whisper, "whisper"),
                      (.parakeet, "parakeet-v3"), (.appleSpeech, "apple-speech")])
    func everyEngineTranscribes(engine: EngineID, call: String) async throws {
        let start = RunTimeRouting.meetingStart(
            segment: .recordOnly,
            route: RunTimeRoute(engine: engine, modelID: nil, unavailable: nil, baseProvider: .local))
        #expect(start.recordOnly && start.provider == .local && !start.localPreview)
        #expect(start.runningEngine == engine)

        let fakes = FakeQueueEngines()
        let transcript = try await fakes.runner.transcribe(start.runningEngine, diarize: true, hints: [])
        #expect(fakes.calls == [call])
        #expect(!transcript.text.isEmpty)
        #expect(fakes.translations.isEmpty)
    }

    @Test("Diduny Cloud in Record only asks for speaker labels")
    func cloudSpeakerLabels() async throws {
        let fakes = FakeQueueEngines()
        _ = try await fakes.runner.transcribe(.didunyCloud, diarize: true, hints: ["uk"])
        #expect(fakes.cloudConfigs.first?["enable_speaker_diarization"] as? Bool == true)
    }

    @Test("A calendar meeting starts in the Modes segment; localRecording is ignored (T5-AP-05)")
    func calendarFollowsModes() throws {
        let defaults = try #require(UserDefaults(suiteName: "test.\(UUID().uuidString)"))
        var calendar = CalendarConfiguration()
        calendar.localRecording = false
        defaults.set(try JSONEncoder().encode(calendar), forKey: "calendar.connection.v1")
        let modes = ModeDefaults(defaults: defaults)
        modes.apply([.startsIn(.recordOnly), .segmentEngine(.recordOnly, JobProviderSelection(providerID: "apple-speech"))])

        let segment = RunTimeRouting.calendarSegment(localOverride: nil, startsIn: modes.meetingStartsIn, showsThisMac: true)
        let route = RunTimeRouting.route(job: .meeting, segment: segment, defaults: modes,
                                         readiness: FakeEngineReadinessSource(),
                                         whisper: .init(downloaded: [], selected: nil), signedIn: true)
        let start = RunTimeRouting.meetingStart(segment: segment, route: route)
        #expect(start.segment == .recordOnly && start.recordOnly)
        #expect(start.engine == .appleSpeech)
    }

    @Test("What the reminder shows is what runs: This Mac means the engine runs on the device",
          arguments: [(MeetingSegment.thisMac, EngineID.whisper), (.cloud, .didunyCloud), (.cloud, .elevenLabs),
                      (.recordOnly, .parakeet), (.recordOnly, .appleSpeech), (.recordOnly, .didunyCloud),
                      (.recordOnly, .elevenLabs)])
    func shownIsWhatRuns(segment: MeetingSegment, engine: EngineID) {
        let routeFor: (MeetingSegment, EngineID) -> MeetingStartRoute = { segment, engine in
            RunTimeRouting.meetingStart(segment: segment,
                                        route: RunTimeRoute(engine: engine, modelID: nil, unavailable: nil, baseProvider: .local))
        }
        let start = routeFor(segment, engine)
        let shown = RunTimeRouting.calendarShowsThisMac(start)
        #expect(shown == [.whisper, .parakeet, .appleSpeech].contains(engine))
        for pick in [nil, true, false] as [Bool?] {
            let runs = RunTimeRouting.calendarSegment(localOverride: pick, startsIn: segment, showsThisMac: shown)
            // The segment that runs keeps the shown engine, or switches to This Mac (Whisper) or Cloud.
            let runsOnDevice = runs == segment ? shown : runs == .thisMac
            #expect(runsOnDevice == (pick ?? shown), "pick \(String(describing: pick)) on \(segment) \(engine)")
        }
    }
}
