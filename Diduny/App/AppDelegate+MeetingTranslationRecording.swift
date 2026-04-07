import AppKit
import Foundation

// MARK: - Meeting Translation Recording

extension AppDelegate {
    @objc func toggleMeetingTranslationRecording() {
        let meetingTranslationRecordingState = appState.meetingTranslationRecordingState
        Log.app
            .info(
                "toggleMeetingTranslationRecording called, current state: \(meetingTranslationRecordingState)"
            )
        meetingTranslationPipelineTask?.cancel()
        meetingTranslationPipelineTask = Task {
            await self.performToggleMeetingTranslationRecording()
        }
    }

    func performToggleMeetingTranslationRecording() async {
        let meetingTranslationRecordingState = appState.meetingTranslationRecordingState
        switch meetingTranslationRecordingState {
        case .idle:
            await startMeetingTranslationRecording()
        case .recording:
            await stopMeetingTranslationRecording()
        case .processing:
            Log.app.info("Meeting translation state is processing, canceling...")
            await cancelMeetingTranslationRecording(cancelTask: false)
        default:
            Log.app.info("Meeting translation state is \(meetingTranslationRecordingState), ignoring toggle")
        }
    }

    func cancelMeetingTranslationRecording(cancelTask: Bool = true) async {
        Log.app.info("cancelMeetingTranslationRecording: BEGIN")

        // Cancel any in-flight pipeline task (skip when called from within the task itself)
        if cancelTask {
            meetingTranslationPipelineTask?.cancel()
        }
        meetingTranslationPipelineTask = nil

        let recordingStartTime = appState.meetingTranslationRecordingStartTime
        let stopTime = Date()

        // Deactivate escape cancel handler
        EscapeCancelService.shared.deactivate()

        // Disconnect real-time translation (if active)
        if appState.liveTranscriptStore != nil {
            await realtimeTranscriptionService.disconnect()
            meetingRecorderService.onRealtimeAudioData = nil
        }

        if SettingsStorage.shared.escapeCancelSaveAudio, meetingRecorderService.isRecording {
            do {
                if let audioURL = try await meetingRecorderService.stopRecording() {
                    let duration = recordingStartTime.map { stopTime.timeIntervalSince($0) } ?? 0
                    RecordingsLibraryStorage.shared.saveRecording(
                        audioURL: audioURL,
                        type: .meeting,
                        duration: duration
                    )
                    try? FileManager.default.removeItem(at: audioURL)
                    Log.app.info("cancelMeetingTranslationRecording: audio saved after cancel")
                } else {
                    await meetingRecorderService.cancelRecording()
                }
            } catch {
                Log.app
                    .warning(
                        "cancelMeetingTranslationRecording: failed to save audio on cancel - \(error.localizedDescription)"
                    )
                await meetingRecorderService.cancelRecording()
            }
        } else {
            // Cancel meeting recorder without persisting
            await meetingRecorderService.cancelRecording()
        }

        // Mark transcript as inactive but keep window open for review
        await MainActor.run {
            appState.liveTranscriptStore?.isActive = false
            appState.liveTranscriptStore = nil
        }

        // End App Nap prevention
        if let token = meetingTranslationActivityToken {
            ProcessInfo.processInfo.endActivity(token)
            meetingTranslationActivityToken = nil
        }

        // Clear recovery state
        RecoveryStateManager.shared.clearState()

        // Reset state to idle
        await MainActor.run {
            appState.meetingTranslationRecordingState = .idle
            appState.meetingTranslationRecordingStartTime = nil
            handleMeetingTranslationStateChange(.idle)
        }

        Log.app.info("cancelMeetingTranslationRecording: END")
    }

    func startMeetingTranslationRecording() async {
        Log.app.info("startMeetingTranslationRecording: BEGIN")

        guard canStartRecording(kind: .meetingTranslation) else {
            Log.app.info("startMeetingTranslationRecording: blocked by another active recording mode")
            return
        }

        // Request screen capture permission on-demand
        let hasPermission = await PermissionManager.shared.ensureScreenRecordingPermission()
        appState.screenCapturePermissionGranted = hasPermission

        guard hasPermission else {
            Log.app.warning("Screen capture permission not granted")
            await MainActor.run {
                appState.errorMessage = "Screen recording permission required for meeting capture"
                appState.meetingTranslationRecordingState = .error
                handleMeetingTranslationStateChange(.error)
            }
            return
        }

        // Meeting translation uses cloud realtime by default

        // Prevent App Nap during meeting translation recording
        meetingTranslationActivityToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "Meeting translation recording in progress"
        )

        // Show processing state while initializing (before we confirm it works)
        await MainActor.run {
            appState.meetingTranslationRecordingState = .processing
            handleMeetingTranslationStateChange(.processing)
        }

        do {
            meetingRecorderService.audioSource = SettingsStorage.shared.meetingAudioSource
            meetingRecorderService.onRealtimeAudioData = nil

            if meetingRecorderService.audioSource == .systemPlusMicrophone {
                let (device, didFallback) = audioDeviceManager.resolveDevice(
                    preferredUID: appState.preferredDeviceUID
                )
                appState.deviceFallbackWarning = nil
                if let device {
                    Log.app.info(
                        "startMeetingTranslationRecording: Device resolution result = \(device.name), transport=\(device.transportType.displayName), sampleRate=\(Int(device.sampleRate)), uid=\(device.uid)"
                    )
                }
                if didFallback, let name = device?.name {
                    Log.app.warning("startMeetingTranslationRecording: Preferred device unavailable, using \(name)")
                    appState.deviceFallbackWarning = "Selected microphone unavailable. Using \(name)"
                    if device?.isDefault == true {
                        appState.preferredDeviceUID = nil
                        Log.app
                            .info(
                                "startMeetingTranslationRecording: Cleared stale preferred microphone UID and switched to System Default"
                            )
                    }
                }
                meetingRecorderService.microphoneDevice = device
            } else {
                meetingRecorderService.microphoneDevice = nil
                appState.deviceFallbackWarning = nil
            }

            try await meetingRecorderService.startRecording()
            Log.app.info("Meeting translation recording started")

            // Stream realtime meeting translation
            let store = await setupRealtimeMeetingTranslation()

            // Only set recording state AFTER confirmed working
            let recordingStateAfterStart = appState.meetingTranslationRecordingState
            guard recordingStateAfterStart == .processing else {
                Log.app
                    .warning(
                        "startMeetingTranslationRecording: state changed during init (now \(recordingStateAfterStart)), aborting"
                    )
                await meetingRecorderService.cancelRecording()
                if let token = meetingTranslationActivityToken {
                    ProcessInfo.processInfo.endActivity(token)
                    meetingTranslationActivityToken = nil
                }
                return
            }
            await MainActor.run {
                appState.meetingTranslationRecordingState = .recording
                appState.meetingTranslationRecordingStartTime = Date()
                appState.liveTranscriptStore = store
                handleMeetingTranslationStateChange(.recording)
            }

            await MainActor.run {
                TranscriptionWindowController.shared.showWindow(store: store)
            }

            // Activate escape cancel handler
            await MainActor.run {
                setupMeetingTranslationEscapeCancelHandler()
            }

            // Save recovery state in case of crash
            if let path = meetingRecorderService.currentRecordingPath {
                let state = RecoveryState(
                    tempFilePath: path,
                    startTime: Date(),
                    recordingType: .meetingTranslation
                )
                RecoveryStateManager.shared.saveState(state)
            }
        } catch {
            Log.app.error("Meeting translation recording failed: \(error)")

            // End App Nap prevention on failed start
            if let token = meetingTranslationActivityToken {
                ProcessInfo.processInfo.endActivity(token)
                meetingTranslationActivityToken = nil
            }

            await MainActor.run {
                appState.errorMessage = error.localizedDescription
                appState.meetingTranslationRecordingState = .error
                handleMeetingTranslationStateChange(.error)
            }
        }
    }

    // MARK: - Real-Time Meeting Translation Setup

    private func setupRealtimeMeetingTranslation() async -> LiveTranscriptStore {
        let store = await MainActor.run { LiveTranscriptStore() }

        let rtService = realtimeTranscriptionService

        // Stream the exact same mixed mono audio that is written to fallback WAV.
        meetingRecorderService.onRealtimeAudioData = { [weak rtService] pcmData in
            rtService?.sendAudioData(pcmData)
        }

        // Wire token callbacks
        rtService.onTokensReceived = { [weak self, weak store] tokens in
            guard let self else { return }
            let translatedTokens = filterMeetingTranslatedTokens(tokens)
            guard !translatedTokens.isEmpty else { return }
            Task { @MainActor in
                store?.processTokens(translatedTokens)
            }
        }

        rtService.onConnectionStatusChanged = { [weak store] status in
            Task { @MainActor in
                store?.connectionStatus = status
            }
        }

        rtService.onSegmentBoundary = { [weak store] _ in
            Task { @MainActor in
                store?.markSegmentBoundary()
            }
        }

        rtService.onError = { error in
            Log.transcription.error("Realtime meeting translation error: \(error.localizedDescription)")
            // Don't stop recording — file recording continues independently
        }

        // Connect WebSocket (recording continues even if translation socket is unavailable)
        do {
            let sourceLanguage = SettingsStorage.shared.translationLanguageA
            let targetLanguage = SettingsStorage.shared.translationLanguageB

            var languageHints = SettingsStorage.shared.favoriteLanguages

            if !languageHints.contains(sourceLanguage) {
                languageHints.append(sourceLanguage)
            }
            if !languageHints.contains(targetLanguage) {
                languageHints.append(targetLanguage)
            }

            try await rtService.connect(
                languageHints: languageHints,
                strictLanguageHints: !languageHints.isEmpty,
                audioConfig: .defaultPCM16kMono,
                translationConfig: RealtimeTranslationConfig(
                    mode: .oneWay(sourceLanguage: sourceLanguage, targetLanguage: targetLanguage)
                )
            )
            await MainActor.run {
                store.isActive = true
            }
            Log.transcription
                .info(
                    "Meeting real-time translation connected successfully (\(sourceLanguage.uppercased()) -> \(targetLanguage.uppercased()))"
                )
        } catch {
            Log.transcription.error("Meeting real-time translation FAILED to connect: \(error.localizedDescription)")
            await MainActor.run {
                store.isActive = true
                store.connectionStatus = .failed(error.localizedDescription)
            }
            // Recording continues — fallback to async translation on stop
        }

        return store
    }

    private func filterMeetingTranslatedTokens(_ tokens: [RealtimeToken]) -> [RealtimeToken] {
        let translatedStatuses: Set = [
            "translation",
            "translated",
            "translated_text",
            "translation_text",
            "target",
            "output"
        ]

        let translatedTokens = tokens.filter { token in
            guard let status = token.translationStatus?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased(),
                !status.isEmpty
            else {
                return false
            }

            return translatedStatuses.contains(status)
        }
        if !translatedTokens.isEmpty {
            return translatedTokens
        }

        // Fallback for payloads that do not include usable translation_status.
        let hasTranslationStatus = tokens.contains {
            let status = $0.translationStatus?.trimmingCharacters(in: .whitespacesAndNewlines)
            return status?.isEmpty == false
        }
        if !hasTranslationStatus {
            return tokens
        }

        // Additional fallback: prefer target-language tokens if status exists but format changed.
        let targetLang = SettingsStorage.shared.translationLanguageB
        let targetLanguageTokens = tokens.filter {
            $0.language?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == targetLang
        }
        if !targetLanguageTokens.isEmpty {
            return targetLanguageTokens
        }

        return []
    }

    // MARK: - Stop Meeting Translation Recording

    func stopMeetingTranslationRecording() async {
        Log.app.info("stopMeetingTranslationRecording: BEGIN")

        // Deactivate escape cancel handler
        EscapeCancelService.shared.deactivate()

        // Capture recording start time for duration calculation
        let recordingStartTime = appState.meetingTranslationRecordingStartTime

        await MainActor.run {
            appState.meetingTranslationRecordingState = .processing
            handleMeetingTranslationStateChange(.processing)
        }

        // Finalize and disconnect real-time translation (if active)
        let hasRealtimeSession = await MainActor.run { appState.liveTranscriptStore != nil }
        if hasRealtimeSession {
            _ = await realtimeTranscriptionService.finalize()
            await realtimeTranscriptionService.disconnect()
            meetingRecorderService.onRealtimeAudioData = nil
        }

        // Mark store as no longer active
        let store = await MainActor.run { appState.liveTranscriptStore }
        await MainActor.run {
            store?.isActive = false
        }

        // Track audioURL for library save in error path
        var capturedAudioURL: URL?
        let stopTime = Date()
        let recordingId = UUID()

        do {
            guard let audioURL = try await meetingRecorderService.stopRecording() else {
                throw MeetingRecorderError.recordingFailed
            }
            capturedAudioURL = audioURL

            Log.app.info("Meeting translation recording stopped")

            let realtimeText = await MainActor.run { store?.finalTranscriptText ?? "" }

            let text: String
            if !realtimeText.isEmpty {
                text = realtimeText
                Log.app.info("Using real-time meeting translation (\(realtimeText.count) chars)")
            } else {
                Log.app.info("No real-time meeting translation, falling back to async API...")
                let audioData = try await loadAudioData(from: audioURL)
                Log.app.info("Meeting translation recording size = \(audioData.count) bytes")

                text = try await transcriptionService.translateAndTranscribe(audioData: audioData)
                Log.app.info("Async meeting translation received (\(text.count) chars)")
            }

            clipboardService.copy(text: text, behavior: .raw)
            Log.app.info("stopMeetingTranslationRecording: Text copied to clipboard")

            if SettingsStorage.shared.autoPaste {
                Log.app.info("stopMeetingTranslationRecording: Auto-pasting")
                do {
                    try await clipboardService.paste()
                } catch ClipboardError.accessibilityNotGranted {
                    Log.app.warning("stopMeetingTranslationRecording: Accessibility permission needed")
                    PermissionManager.shared.showPermissionAlert(for: .accessibility)
                } catch {
                    Log.app.error("stopMeetingTranslationRecording: Paste failed - \(error.localizedDescription)")
                }
            }

            let processingState = appState.meetingTranslationRecordingState
            guard processingState == .processing else {
                Log.app
                    .warning(
                        "stopMeetingTranslationRecording: state changed during processing (now \(processingState)), dropping result"
                    )
                if let audioURL = capturedAudioURL {
                    try? FileManager.default.removeItem(at: audioURL)
                }
                RecoveryStateManager.shared.clearState()
                return
            }
            await MainActor.run {
                appState.lastTranscription = text
                appState.meetingTranslationRecordingState = .success
                appState.meetingTranslationRecordingStartTime = nil
                handleMeetingTranslationStateChange(.success)
            }
            Log.app.info("stopMeetingTranslationRecording: SUCCESS")

            let duration = recordingStartTime.map { stopTime.timeIntervalSince($0) } ?? 0
            RecordingsLibraryStorage.shared.saveRecording(
                id: recordingId,
                audioURL: audioURL,
                type: .meeting,
                duration: duration,
                transcriptionText: text
            )

            if SettingsStorage.shared.playSoundOnCompletion {
                NSSound(named: .init("Funk"))?.play()
            }

            RecoveryStateManager.shared.clearState()
            try? FileManager.default.removeItem(at: audioURL)

        } catch is CancellationError {
            Log.app.info("stopMeetingTranslationRecording: Cancelled")
            if let audioURL = capturedAudioURL {
                try? FileManager.default.removeItem(at: audioURL)
            }
            RecoveryStateManager.shared.clearState()
            await MainActor.run {
                appState.meetingTranslationRecordingState = .idle
                appState.meetingTranslationRecordingStartTime = nil
                handleMeetingTranslationStateChange(.idle)
            }
            return
        } catch {
            Log.app.error("Meeting translation failed: \(error)")

            if let audioURL = capturedAudioURL {
                let duration = recordingStartTime.map { stopTime.timeIntervalSince($0) } ?? 0
                RecordingsLibraryStorage.shared.saveRecording(
                    id: recordingId,
                    audioURL: audioURL,
                    type: .meeting,
                    duration: duration
                )
                try? FileManager.default.removeItem(at: audioURL)
                RecoveryStateManager.shared.clearState()
            }

            let processingState = appState.meetingTranslationRecordingState
            guard processingState == .processing else {
                Log.app
                    .warning(
                        "stopMeetingTranslationRecording: state changed during processing (now \(processingState)), dropping error"
                    )
                return
            }

            let userMessage: String = if let transcriptionError = error as? TranscriptionError {
                transcriptionError.localizedDescription
            } else {
                "Translation failed: \(error.localizedDescription). Audio saved to Recordings."
            }

            await MainActor.run {
                appState.errorMessage = userMessage
                appState.meetingTranslationRecordingState = .error
                appState.meetingTranslationRecordingStartTime = nil
                handleMeetingTranslationStateChange(.error)
            }
        }

        // End App Nap prevention
        if let token = meetingTranslationActivityToken {
            ProcessInfo.processInfo.endActivity(token)
            meetingTranslationActivityToken = nil
        }

        // Keep transcript window open — user closes manually

        Log.app.info("stopMeetingTranslationRecording: END")
    }

    // MARK: - Escape Cancel Handler

    private func setupMeetingTranslationEscapeCancelHandler() {
        let escapeService = EscapeCancelService.shared
        guard SettingsStorage.shared.escapeCancelEnabled else {
            escapeService.deactivate()
            return
        }

        // On first shortcut press: show confirmation notification
        escapeService.onFirstEscape = { [weak self] in
            NotchManager.shared.showInfo(
                message: SettingsStorage.shared.escapeCancelShortcut.repeatHint,
                duration: 1.5
            )

            // Resume showing recording state after info disappears
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(1.6))
                guard let self,
                      appState.meetingTranslationRecordingState == .recording else { return }
                NotchManager.shared.startRecording(mode: .meetingTranslation)
            }
        }

        // On second shortcut press (confirmed cancel): cancel recording
        escapeService.onCancel = { [weak self] in
            Task { @MainActor in
                let shouldSaveAudio = SettingsStorage.shared.escapeCancelSaveAudio
                await self?.cancelMeetingTranslationRecording()
                let message = shouldSaveAudio ? "Recording cancelled and saved" : "Recording cancelled"
                NotchManager.shared.showInfo(message: message)
            }
        }

        escapeService.activate()
    }
}
