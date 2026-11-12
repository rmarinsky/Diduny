import Foundation

// MARK: - Stop After Silence

extension AppDelegate {
    /// Call before the audio recorder starts: it snapshots `onAnalysisAudioData` at start.
    /// `job`: `.dictation` or `.dictationTranslation`, each with its own "Stop after silence" (05 Q5).
    func startDictationSilenceMonitor(
        job: STTJob,
        pushToTalk: PushToTalkService,
        stop: @escaping @MainActor () async -> Void
    ) {
        stopDictationSilenceMonitor()
        let silence = SettingsStorage.shared.silenceAutoStop(for: job)
        guard silence.enabled else { return }

        let monitor = SilenceAutoStopMonitor(timeout: silence.seconds) { [weak pushToTalk] decision in
            // A held hold-to-record key means the person is still in control.
            let isHeld = pushToTalk?.isHoldingToRecord == true
            Self.applySilenceDecision(isHeld ? .keepRecording : decision) {
                pushToTalk?.resetHandsFreeMode()
                await stop()
            }
        }
        dictationSilenceMonitor = monitor
        audioRecorder.onAnalysisAudioData = { [weak monitor] data in
            monitor?.append(pcm16: data)
        }
    }

    func stopDictationSilenceMonitor() {
        audioRecorder.onAnalysisAudioData = nil
        guard let monitor = dictationSilenceMonitor else { return }
        monitor.finish()
        dictationSilenceMonitor = nil
        DictationOverlayController.shared.updateSilenceCountdown(nil)
    }

    /// `job`: `.meeting` or `.meetingTranslation`.
    func startMeetingSilenceMonitor(job: STTJob, stop: @escaping @MainActor () async -> Void) {
        stopMeetingSilenceMonitor()
        let silence = SettingsStorage.shared.silenceAutoStop(for: job)
        guard silence.enabled else { return }

        let monitor = SilenceAutoStopMonitor(timeout: silence.seconds) { [weak self] decision in
            guard let self, decision != .keepRecording, self.isMeetingStillGoingOn() else {
                Self.applySilenceDecision(decision, stop: stop)
                return
            }
            // The meeting is still going on: no countdown, and a due stop starts the silence timer over.
            Self.applySilenceDecision(.keepRecording, stop: stop)
            if decision == .stop {
                Log.app.info("Silence auto-stop: meeting still going on, keeping the recording")
                self.startMeetingSilenceMonitor(job: job, stop: stop)
            }
        }
        meetingSilenceMonitor = monitor
        meetingRecorderService.onMixedSamples = { [weak monitor] samples in
            monitor?.append(samples: samples)
        }
    }

    /// The call is still active, or the calendar meeting linked to this recording has not ended.
    private func isMeetingStillGoingOn(now: Date = Date()) -> Bool {
        let stored = meetingRecorderService.currentRecordingId.flatMap { id in
            RecordingsLibraryStorage.shared.recordings.first(where: { $0.id == id })?.calendarMeeting
        }
        // A meeting extended in Calendar after linking ends when Calendar now says.
        let linked = stored.map { stored in CalendarConnection.shared.meetings.first(where: { $0.id == stored.id }) ?? stored }
        return CalendarMeeting.silenceStopHeld(meeting: linked, callActive: meetingJoinMonitor.isCallActive, now: now)
    }

    func stopMeetingSilenceMonitor() {
        meetingRecorderService.onMixedSamples = nil
        guard let monitor = meetingSilenceMonitor else { return }
        monitor.finish()
        meetingSilenceMonitor = nil
        DictationOverlayController.shared.updateSilenceCountdown(nil)
    }

    @MainActor
    private static func applySilenceDecision(
        _ decision: SilenceAutoStopTimer.Decision,
        stop: @escaping @MainActor () async -> Void
    ) {
        switch decision {
        case .keepRecording:
            DictationOverlayController.shared.updateSilenceCountdown(nil)
        case let .countdown(secondsLeft):
            DictationOverlayController.shared.updateSilenceCountdown(secondsLeft)
        case .stop:
            DictationOverlayController.shared.updateSilenceCountdown(nil)
            Log.app.info("Silence auto-stop: stopping recording after silence")
            Task { await stop() }
        }
    }
}
