import Testing

@testable import Diduny

@Suite("NotchManager State Machine")
@MainActor
struct NotchManagerTests {
    private var sut: NotchManager { NotchManager.shared }

    init() {
        NotchManager.shared.hide()
        NotchManager.shared.setStopHandler(nil)
    }

    // MARK: - startRecording

    @Test("startRecording sets recordingStartTime and transitions to recording state")
    func startRecordingSetsTimestamp() {
        let before = Date()
        sut.startRecording(mode: .voice)
        let after = Date()

        #expect(sut.state == .recording(mode: .voice))
        #expect(sut.recordingStartTime != nil)
        #expect(sut.recordingStartTime! >= before)
        #expect(sut.recordingStartTime! <= after)
    }

    @Test("startRecording with different modes", arguments: [
        RecordingMode.voice,
        RecordingMode.meeting,
        RecordingMode.meetingTranslation,
        RecordingMode.fileTranscription,
    ])
    func startRecordingWithMode(mode: RecordingMode) {
        sut.startRecording(mode: mode)
        #expect(sut.state == .recording(mode: mode))
        #expect(sut.recordingStartTime != nil)
    }

    // MARK: - resumeRecording (timer restart bug fix)

    @Test("resumeRecording preserves existing recordingStartTime")
    func resumeRecordingPreservesTimestamp() {
        sut.startRecording(mode: .voice)
        let originalStartTime = sut.recordingStartTime

        sut.resumeRecording(mode: .voice)

        #expect(sut.state == .recording(mode: .voice))
        #expect(sut.recordingStartTime == originalStartTime,
                "resumeRecording must NOT reset recordingStartTime")
    }

    @Test("resumeRecording without prior startRecording leaves recordingStartTime nil")
    func resumeRecordingWithoutStart() {
        sut.resumeRecording(mode: .voice)

        #expect(sut.state == .recording(mode: .voice))
        #expect(sut.recordingStartTime == nil)
    }

    @Test("startRecording after resumeRecording sets a NEW timestamp")
    func startAfterResumeResetsTimestamp() {
        sut.resumeRecording(mode: .voice)
        #expect(sut.recordingStartTime == nil)

        sut.startRecording(mode: .voice)
        #expect(sut.recordingStartTime != nil)
    }

    // MARK: - startProcessing

    @Test("startProcessing clears recording metadata")
    func startProcessingClearsMetadata() {
        sut.startRecording(mode: .voice)
        sut.audioLevel = 0.5
        #expect(sut.recordingStartTime != nil)

        sut.startProcessing(mode: .voice)

        #expect(sut.state == .processing(mode: .voice))
        #expect(sut.recordingStartTime == nil)
        #expect(sut.audioLevel == 0)
    }

    // MARK: - showSuccess

    @Test("showSuccess sets state and clears recording metadata")
    func showSuccessSetsState() {
        sut.startRecording(mode: .voice)
        sut.audioLevel = 0.5

        sut.showSuccess(text: "Hello world")

        #expect(sut.state == .success(text: "Hello world"))
        #expect(sut.recordingStartTime == nil)
        #expect(sut.audioLevel == 0)
    }

    // MARK: - showError

    @Test("showError sets state and clears recording metadata")
    func showErrorSetsState() {
        sut.startRecording(mode: .voice)

        sut.showError(message: "Something went wrong")

        #expect(sut.state == .error(message: "Something went wrong"))
        #expect(sut.recordingStartTime == nil)
    }

    // MARK: - showInfo

    @Test("showInfo sets info state")
    func showInfoSetsState() {
        sut.showInfo(message: "Press Esc 1 more time to cancel")
        #expect(sut.state == .info(message: "Press Esc 1 more time to cancel"))
    }

    @Test("showInfo during recording does not clear recordingStartTime")
    func showInfoPreservesRecordingStartTime() {
        sut.startRecording(mode: .voice)
        let originalStartTime = sut.recordingStartTime

        sut.showInfo(message: "hint")

        #expect(sut.state == .info(message: "hint"))
        #expect(sut.recordingStartTime == originalStartTime)
    }

    // MARK: - hide

    @Test("hide resets all state to idle")
    func hideResetsToIdle() {
        sut.startRecording(mode: .voice)
        sut.audioLevel = 0.8

        sut.hide()

        #expect(sut.state == .idle)
        #expect(sut.recordingStartTime == nil)
        #expect(sut.audioLevel == 0)
    }

    // MARK: - requestStopActiveRecording

    @Test("requestStopActiveRecording fires handler when recording")
    func requestStopFiresHandler() async {
        var handlerCalled = false
        sut.setStopHandler { handlerCalled = true }
        sut.startRecording(mode: .voice)

        sut.requestStopActiveRecording()

        // Handler runs in a Task — yield to let it execute
        try? await Task.sleep(for: .milliseconds(50))
        #expect(handlerCalled)
    }

    @Test("requestStopActiveRecording does nothing when idle")
    func requestStopNoopWhenIdle() async {
        var handlerCalled = false
        sut.setStopHandler { handlerCalled = true }

        sut.requestStopActiveRecording()

        try? await Task.sleep(for: .milliseconds(50))
        #expect(!handlerCalled)
    }

    @Test("requestStopActiveRecording does nothing when processing")
    func requestStopNoopWhenProcessing() async {
        var handlerCalled = false
        sut.setStopHandler { handlerCalled = true }
        sut.startProcessing(mode: .voice)

        sut.requestStopActiveRecording()

        try? await Task.sleep(for: .milliseconds(50))
        #expect(!handlerCalled)
    }

    @Test("requestStopActiveRecording does nothing without handler")
    func requestStopNoopWithoutHandler() {
        sut.startRecording(mode: .voice)
        sut.requestStopActiveRecording()
        #expect(sut.state == .recording(mode: .voice))
    }

    // MARK: - Full flow

    @Test("Complete flow: start -> process -> success -> hide")
    func completeFlow() {
        sut.startRecording(mode: .voice)
        #expect(sut.state == .recording(mode: .voice))
        #expect(sut.recordingStartTime != nil)

        sut.startProcessing(mode: .voice)
        #expect(sut.state == .processing(mode: .voice))
        #expect(sut.recordingStartTime == nil)

        sut.showSuccess(text: "Done")
        #expect(sut.state == .success(text: "Done"))

        sut.hide()
        #expect(sut.state == .idle)
    }

    @Test("Error flow: start -> process -> error")
    func errorFlow() {
        sut.startRecording(mode: .meeting)
        sut.startProcessing(mode: .meeting)
        sut.showError(message: "Timeout")

        #expect(sut.state == .error(message: "Timeout"))
    }

    @Test("ESC info flow: start -> showInfo -> resumeRecording preserves timer")
    func escInfoFlowPreservesTimer() {
        sut.startRecording(mode: .voice)
        let originalStartTime = sut.recordingStartTime

        // First ESC press shows info
        sut.showInfo(message: "Press Esc 1 more time to cancel")
        #expect(sut.state == .info(message: "Press Esc 1 more time to cancel"))

        // After info auto-dismisses, recording resumes
        sut.resumeRecording(mode: .voice)
        #expect(sut.state == .recording(mode: .voice))
        #expect(sut.recordingStartTime == originalStartTime,
                "Timer must continue from original start time after ESC info")
    }
}
