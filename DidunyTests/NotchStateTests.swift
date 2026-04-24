import Testing

@testable import Diduny

@Suite("NotchState and RecordingMode")
struct NotchStateTests {
    @Test("Equal states are equal")
    func equalStates() {
        #expect(NotchState.idle == NotchState.idle)
        #expect(NotchState.recording(mode: .voice) == NotchState.recording(mode: .voice))
        #expect(NotchState.success(text: "a") == NotchState.success(text: "a"))
        #expect(NotchState.error(message: "x") == NotchState.error(message: "x"))
        #expect(NotchState.info(message: "i") == NotchState.info(message: "i"))
    }

    @Test("Different states are not equal")
    func differentStates() {
        #expect(NotchState.idle != NotchState.recording(mode: .voice))
        #expect(NotchState.recording(mode: .voice) != NotchState.recording(mode: .meeting))
        #expect(NotchState.success(text: "a") != NotchState.success(text: "b"))
        #expect(NotchState.recording(mode: .voice) != NotchState.processing(mode: .voice))
    }

    @Test("RecordingMode labels and icons are non-empty")
    func recordingModeProperties() {
        let modes: [RecordingMode] = [
            .voice, .translation(), .meeting, .meetingTranslation, .fileTranscription,
        ]
        for mode in modes {
            #expect(!mode.label.isEmpty)
            #expect(!mode.processingLabel.isEmpty)
            #expect(!mode.icon.isEmpty)
        }
    }
}
