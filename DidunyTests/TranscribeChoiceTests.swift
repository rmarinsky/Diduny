@testable import Diduny
import Testing

@Suite("Transcribe choice in the recording inspector")
struct TranscribeChoiceTests {
    private func facts(_ downloaded: Set<TranscribeChoice.MacModel> = [.parakeet, .whisperTurbo], appleSilicon: Bool = true,
                       speakerModel: Bool = true) -> TranscribeFacts {
        TranscribeFacts(appleSilicon: appleSilicon, speakerModelSupported: speakerModel, speakerModelReady: speakerModel,
                        downloaded: downloaded, appleSpeechReady: true, elevenLabsKey: false)
    }

    @Test func labelsDefaultOnWithWhisperAndOffWhenWhisperIsMissing() {
        let ready = TranscribeChoice.defaults(offersLabels: true, facts: facts())
        #expect(ready.labels && ready.mac == .whisperTurbo)
        let missing = TranscribeChoice.defaults(offersLabels: true, facts: facts([.parakeet]))
        #expect(!missing.labels && missing.mac == .parakeet)
        let note = TranscribeChoice.defaults(offersLabels: false, facts: facts())
        #expect(!note.labels && note.mac == .parakeet)
        let intel = TranscribeChoice.defaults(offersLabels: false, facts: facts([], appleSilicon: false))
        #expect(intel.mac == .whisperTurbo)
    }

    @Test func turningLabelsOnSwitchesAParakeetChoiceToWhisperWithANote() {
        var choice = TranscribeChoice.defaults(offersLabels: true, facts: facts([.parakeet]))
        choice.setLabels(true)
        #expect(choice.mac == .whisperTurbo)
        #expect(choice.note == .modelChangedForLabels)
        #expect(choice.blocker(facts([.parakeet])) == .download(.whisperTurbo))
    }

    @Test func pickingParakeetTurnsLabelsOffWithANote() {
        var choice = TranscribeChoice.defaults(offersLabels: true, facts: facts())
        choice.pick(.parakeet)
        #expect(!choice.labels)
        #expect(choice.note == .labelsOffForModel)
    }

    @Test func localRunWithoutLabelsIsAPerRunOptionNotTheGlobalSetting() {
        var choice = TranscribeChoice.defaults(offersLabels: true, facts: facts())
        choice.setLabels(false)
        let run = choice.run(offersLabels: true)
        #expect(run == .init(action: .transcribe, engine: .whisper, whisperModel: "ggml-large-v3-turbo", speakerLabels: false))
        choice.setLabels(true)
        #expect(choice.run(offersLabels: true).speakerLabels == true)
        #expect(choice.run(offersLabels: false).speakerLabels == nil, "Voice notes follow the default")
    }

    @Test func cloudLabelsAskTheServiceToDiarize() {
        var choice = TranscribeChoice.defaults(offersLabels: true, facts: facts())
        choice.pick(.elevenLabs)
        #expect(choice.place == .cloud)
        #expect(choice.run(offersLabels: true) == .init(action: .transcribeDiarize, engine: .elevenLabs, whisperModel: nil, speakerLabels: nil))
        choice.setLabels(false)
        #expect(choice.run(offersLabels: true).action == .transcribe)
        #expect(choice.blocker(facts([])) == nil)
    }

    @Test func parakeetIsNotOnIntelAndLabelsWithoutTheSpeakerModelAreMeAndOthers() {
        var choice = TranscribeChoice.defaults(offersLabels: false, facts: facts())
        choice.pick(.parakeet)
        #expect(choice.blocker(facts(appleSilicon: false)) == .notOnThisMac)
        choice.setLabels(true)
        #expect(choice.meAndOthersOnly(facts(speakerModel: false)))
        #expect(!choice.meAndOthersOnly(facts()))
    }
}
