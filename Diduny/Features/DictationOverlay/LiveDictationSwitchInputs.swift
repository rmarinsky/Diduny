import Foundation

/// WP-64: the dictation and translation panels' Engine picker during a recording. Clicks go through the same
/// `meetingSwitchHandler` a meeting uses; the app sets it once the recording runs.
extension LiveDictationOverlayStore {
    private var dictationJob: STTJob {
        if case .translation = mode { return .dictationTranslation }
        return .dictation
    }

    var canSwitchDictationEngine: Bool {
        !mode.isMeeting && phase == .recording && meetingSwitchHandler != nil
    }

    /// The menu before Start (02 section 3), with the running engine selected.
    var dictationEngineMenu: PickerMenuModel {
        CommandHome.engineMenu(
            pick: sessionEngine?.id,
            caps: EdgeCommandPanelController.engineCapabilities,
            readiness: EdgeCommandPanelController.engineReadiness
        )
    }

    func pickDictationEngine(rowID: String) {
        if rowID == CommandHome.providersRowID {
            AppDelegate.current?.openMainWindow(section: .providers)
            return
        }
        let engine = rowID == CommandHome.asInSettingsRowID
            ? SettingsStorage.shared.modeDefaults.engine(for: dictationJob)
            : EngineID(rawValue: rowID)
        guard let engine else { return }
        meetingSwitchHandler?.click(.live(engine))
    }

    /// Under the Engine field: connecting, why a switch failed, or that the rest comes after Stop.
    var dictationSwitchLine: String? {
        guard !mode.isMeeting, meetingSwitchHandler != nil else { return nil }
        if let pending = meetingSwitch.pending {
            return String(localized: "Connecting to \(MeetingPanelState.name(pending.engine))...")
        }
        if meetingSwitch.failure != nil,
           let line = MeetingSwitchText.line(meetingSwitch, translateMeeting: true, canUseAppleSpeech: false, canUseElevenLabs: false) {
            return line.message
        }
        guard meetingSwitch.switched, hasText, let engine = sessionEngine else { return nil }
        if !engine.hasLiveText { return String(localized: "The rest of the text comes after Stop.") }
        if case .translation = mode, engine.id != .didunyCloud {
            return String(localized: "The rest is translated after Stop.")
        }
        return nil
    }
}
