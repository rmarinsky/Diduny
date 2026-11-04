import Foundation

// MARK: - Stop After Silence

extension AppDelegate {
    /// Call before the audio recorder starts: it snapshots `onAnalysisAudioData` at start.
    func startDictationSilenceMonitor(
        pushToTalk: PushToTalkService,
        stop: @escaping @MainActor () async -> Void
    ) {
        stopDictationSilenceMonitor()
        let settings = SettingsStorage.shared
        guard settings.dictationSilenceAutoStopEnabled else { return }

        let monitor = SilenceAutoStopMonitor(timeout: settings.dictationSilenceAutoStopSeconds) { [weak pushToTalk] decision in
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

    func startMeetingSilenceMonitor(stop: @escaping @MainActor () async -> Void) {
        stopMeetingSilenceMonitor()
        let settings = SettingsStorage.shared
        guard settings.meetingSilenceAutoStopEnabled else { return }

        let monitor = SilenceAutoStopMonitor(timeout: settings.meetingSilenceAutoStopSeconds) { decision in
            Self.applySilenceDecision(decision, stop: stop)
        }
        meetingSilenceMonitor = monitor
        meetingRecorderService.onMixedSamples = { [weak monitor] samples in
            monitor?.append(samples: samples)
        }
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
