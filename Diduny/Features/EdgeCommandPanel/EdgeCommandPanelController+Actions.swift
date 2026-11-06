import AppKit

extension EdgeCommandPanelController {
    func perform(_ action: EdgeCommandAction) {
        guard let appDelegate else { return }
        let pair = model?.selectedPair

        switch action {
        case .transcribe:
            if appDelegate.appState.recordingState == .idle {
                guard appDelegate.canStartRecording(kind: .voice) else { showCollapsed(); return }
            }
            appDelegate.toggleRecording()
        case .translate:
            if appDelegate.appState.translationRecordingState == .idle {
                guard appDelegate.canStartRecording(kind: .translation), let pair else { showCollapsed(); return }
                Task { await appDelegate.startTranslationRecording(languagePair: pair) }
            } else {
                appDelegate.toggleTranslationRecording()
            }
        case .meeting:
            if appDelegate.appState.meetingRecordingState == .idle {
                guard appDelegate.canStartRecording(kind: .meeting) else { showCollapsed(); return }
            }
            appDelegate.toggleMeetingRecording()
        case .translateMeeting:
            if appDelegate.appState.meetingTranslationRecordingState == .idle {
                guard appDelegate.canStartRecording(kind: .meetingTranslation),
                      let pair else { showCollapsed(); return }
                Task { await appDelegate.startMeetingTranslationRecording(languagePair: pair) }
            } else {
                appDelegate.toggleMeetingTranslationRecording()
            }
        case .batch:
            appDelegate.batchFilesAndURLs()
            showCollapsed()
        }
    }
}
