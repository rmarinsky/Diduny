#if TEST_BUILD
    import AppKit

    /// `-uiStateFixture <name>` (implementation-plan WP-90, section 7.2): a named launch profile, that is
    /// flags plus a seed, then an open target. Data only; the app draws every state itself.
    struct UITestStateFixture {
        let flags: [String]
        let seed: [String: Any]

        /// Profile `P-STD` (test-plan 2.2).
        static let standardFlags = [
            "--ui-testing-signed-in", "--ui-testing-quota=available", "--ui-testing-stub-engines",
            "--ui-testing-stub-paste", "--ui-testing-fixed-clock=2026-11-06T10:00:00Z",
            "--ui-testing-command-panel-pinned", "--ui-testing-power=ac", "--ui-testing-parakeet=downloaded",
            "--ui-testing-whisper-models=ggml-large-v3-turbo:active", "--ui-testing-elevenlabs-key=absent",
            "--ui-testing-apple-speech=available", "--ui-testing-input-bridge", "--ui-testing-probe",
            "--ui-testing-reduce-motion",
        ]
        static let standardSeed: [String: Any] = [
            "defaults": ["recordingFeedbackSurface": "compactPanel", "edgePanelDockEdge": "right"],
        ]

        static func named(in arguments: [String]) -> UITestStateFixture? {
            guard let index = arguments.firstIndex(of: UITestHarness.fixtureArgument), index + 1 < arguments.count else { return nil }
            return all[arguments[index + 1]]
        }

        private static func std(_ open: String, _ extra: [String] = [], seed: [String: Any] = [:]) -> UITestStateFixture {
            var merged = standardSeed
            for (key, value) in seed {
                merged[key] = (merged[key] as? [String: Any] ?? [:]).merging(value as? [String: Any] ?? [:]) { _, new in new }
            }
            return UITestStateFixture(flags: standardFlags + extra + ["--ui-testing-open=\(open)"], seed: merged)
        }

        /// One per data-reachable row of implementation-plan 7.2. Menu and popup states open from these
        /// with one click in `RedesignCaptureTests`.
        static let all: [String: UITestStateFixture] = [
            "meeting-cloud": std("livePanel.meeting.cloudLive"),
            "meeting-thismac": std("livePanel.meeting.localLive"),
            "meeting-battery": std("livePanel.meeting.localLive", ["--ui-testing-power=battery"]),
            "meeting-recordonly": std("livePanel.meeting.recordOnly"),
            "dictation-original": std("livePanel.dictation"),
            "dictation-parakeet": std("livePanel.dictation", seed: ["jobDefaults": ["dictation": ["providerID": "parakeet-v3"]]]),
            "tmeeting-live-original": std("livePanel.meetingTranslation", seed: ["defaults": ["meetingTranslationShowOriginal": true]]),
            "home": std("commandPanel.home"),
            "home-signedout": std("commandPanel.home", ["--ui-testing-signed-out"]),
            "prompt": std("commandPanel.prompt"),
            "providers-key": std("settings.providers", ["--ui-testing-elevenlabs-key=present"]),
            "providers-nokey": std("settings.providers"),
            "models": std("settings.models"),
            "modes-meeting": std("settings.modes.meeting"),
            "modes-signedout": std("settings.modes", ["--ui-testing-signed-out"]),
            "general": std("settings.general"),
            "languages": std("settings.languages"),
            "audio": std("settings.audioDictation", ["--ui-testing-audio-devices=Test Mic A,Test Mic B"]),
            "shortcuts": std("settings.shortcuts"),
        ]
    }

    // MARK: - Open targets (test-plan 2.2 `--ui-testing-open`)

    @MainActor
    enum UITestOpenTarget {
        /// Called at the end of `applicationDidFinishLaunching`.
        static func didFinishLaunching(_ appDelegate: AppDelegate) {
            if UITestHarness.listensToBridge { UITestBridge.shared.start() }
            if UITestHarness.showsProbe { UITestProbe.shared.show(appState: appDelegate.appState) }
            guard let target = UITestHarness.openTarget else { return }
            open(target, appDelegate: appDelegate)
        }

        /// `settings.modes.meeting` expands that row (read by `ModesSettingsView`).
        static var requestedModesJob: STTJob? {
            guard let target = UITestHarness.openTarget, target.hasPrefix("settings.modes.") else { return nil }
            return STTJob(rawValue: String(target.dropFirst("settings.modes.".count)))
        }

        static func open(_ target: String, appDelegate: AppDelegate) {
            let parts = target.split(separator: ".").map(String.init)
            switch parts.first {
            case "settings":
                let section = parts.count > 1 ? MainSection(rawValue: parts[1]) : nil
                appDelegate.openMainWindow(section: section ?? .general)
            case "commandPanel":
                if parts.count > 1, parts[1] == "prompt" {
                    EdgeCommandPanelController.shared.showMeetingSuggestion(DetectedMeeting(id: UUID(), client: .zoom))
                } else {
                    // Launch already showed the tab; expand once its placement has landed, as a hover would.
                    DispatchQueue.main.async { EdgeCommandPanelController.shared.expandForUITesting() }
                }
            case "onboarding":
                OnboardingWindowController.shared.showOnboarding()
            case "livePanel":
                guard parts.count > 1 else { return }
                let segment = parts.count > 2 ? segment(parts[2]) : nil
                startLivePanel(job: parts[1], segment: segment, appDelegate: appDelegate)
            default:
                NSLog("[Diduny] UI testing: unknown open target %@", target)
            }
        }

        private static func segment(_ id: String) -> MeetingSegment? {
            switch id {
            case "localLive": .thisMac
            case "cloudLive": .cloud
            case "recordOnly": .recordOnly
            default: nil
            }
        }

        /// Drives the live panel through the calls the recording flow makes at start (begin, output,
        /// running engine, connected), with the scripted transcript in place of an STT stream.
        private static func startLivePanel(job: String, segment: MeetingSegment?, appDelegate: AppDelegate) {
            let overlay = DictationOverlayController.shared
            let settings = SettingsStorage.shared
            let mode: RecordingMode
            switch job {
            case "dictation": mode = .voice
            case "dictationTranslation": mode = .translation(targetLanguage: settings.effectiveDictationTranslationTargetLanguage)
            case "meeting": mode = .meeting
            case "meetingTranslation": mode = .meetingTranslation
            default: return
            }
            overlay.begin(mode: mode)
            switch mode {
            case .voice:
                appDelegate.configureRecordingFeedbackOutput(native: .original, provider: appDelegate.routedProvider(for: .dictation))
            case let .translation(target):
                appDelegate.configureRecordingFeedbackOutput(
                    native: .translation(targetLanguage: target), provider: appDelegate.routedTranslationProvider
                )
            case .meeting:
                let running = segment ?? settings.modeDefaults.meetingStartsIn
                overlay.store.showRunningMeeting(segment: running, engine: settings.modeDefaults.engine(for: running))
            case .meetingTranslation:
                overlay.store.showRunningMeetingTranslation(engine: settings.modeDefaults.engine(for: .meetingTranslation))
            case .fileTranscription:
                break
            }
            overlay.startRecording(mode: mode)
            overlay.updateConnectionStatus(.connected)
            if UITestHarness.manualClock != nil { overlay.store.endedAt = overlay.store.startedAt }
            UITestScript.emit(count: UITestHarness.transcriptEmitCount ?? 2)
        }
    }

    // MARK: - Scripted transcript (`DIDUNY_UI_TEST_SCRIPT`, default `two-speakers-en-uk`)

    @MainActor
    enum UITestScript {
        private struct Segment {
            let speaker: String
            let language: String
            let text: String
            let translation: String
        }

        private static let scripts: [String: [Segment]] = [
            "two-speakers-en-uk": [
                Segment(speaker: "1", language: "en", text: "Good morning, let's start the review.", translation: "Доброго ранку, почнімо огляд."),
                Segment(speaker: "2", language: "uk", text: "Так, я підготувала цифри.", translation: "Yes, I prepared the numbers."),
                Segment(speaker: "1", language: "en", text: "Great, share your screen please.", translation: "Чудово, покажи свій екран, будь ласка."),
                Segment(speaker: "2", language: "uk", text: "Зараз покажу.", translation: "I'll show it now."),
            ],
        ]

        private static var next = 0

        /// Emits the next `count` segments as final tokens, as the STT stream would.
        static func emit(count: Int) {
            let name = ProcessInfo.processInfo.environment[UITestHarness.scriptEnvironment] ?? "two-speakers-en-uk"
            let script = scripts[name] ?? []
            let overlay = DictationOverlayController.shared
            let mode = overlay.store.mode
            for _ in 0 ..< count where next < script.count {
                let segment = script[next]
                next += 1
                let speaker = mode.isMeeting ? segment.speaker : nil
                var tokens = [RealtimeToken(text: segment.text + " ", isFinal: true, speaker: speaker, language: segment.language)]
                if mode == .meetingTranslation {
                    let target = segment.language == "en" ? "uk" : "en"
                    tokens.append(RealtimeToken(
                        text: segment.translation + " ", isFinal: true, speaker: speaker, language: target,
                        sourceLanguage: segment.language, translationStatus: "translation"
                    ))
                }
                overlay.processTokens(tokens)
            }
        }
    }
#endif
