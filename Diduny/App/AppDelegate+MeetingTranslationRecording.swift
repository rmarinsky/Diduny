import AppKit
import Foundation

// MARK: - Meeting Translation Recording

extension AppDelegate {
    @objc func toggleMeetingTranslationRecording() {
        Log.app.info("toggleMeetingTranslationRecording called, current state: \(self.appState.meetingTranslationRecordingState)")
        Task {
            await self.performToggleMeetingTranslationRecording()
        }
    }

    func performToggleMeetingTranslationRecording() async {
        switch appState.meetingTranslationRecordingState {
        case .idle:
            await startMeetingTranslationRecording()
        case .recording:
            await stopMeetingTranslationRecording()
        case .processing:
            Log.app.info("Meeting translation state is processing, canceling...")
            await cancelMeetingTranslationRecording()
        default:
            Log.app.info("Meeting translation state is \(self.appState.meetingTranslationRecordingState), ignoring toggle")
        }
    }

    @available(macOS 13.0, *)
    func cancelMeetingTranslationRecording() async {
        Log.app.info("cancelMeetingTranslationRecording: BEGIN")

        // Deactivate escape cancel handler
        EscapeCancelService.shared.deactivate()

        // Disconnect real-time translation (if active)
        if appState.liveTranscriptStore != nil {
            await realtimeTranscriptionService.disconnect()
            meetingRecorderService.onRealtimeAudioData = nil
        }

        // Cancel meeting recorder
        await meetingRecorderService.cancelRecording()

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

        guard #available(macOS 13.0, *) else {
            Log.app.warning("Meeting translation requires macOS 13.0+")
            await MainActor.run {
                appState.errorMessage = "Meeting translation requires macOS 13.0 or later"
                appState.meetingTranslationRecordingState = .error
                handleMeetingTranslationStateChange(.error)
            }
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

        // Hardcoded meeting mode: realtime translation to Ukrainian requires Soniox API key
        guard let apiKey = KeychainManager.shared.getSonioxAPIKey(), !apiKey.isEmpty else {
            Log.app.warning("startMeetingTranslationRecording: No API key found")
            await MainActor.run {
                appState.errorMessage = "Meeting translation requires a Soniox API key. Add one in Settings."
                appState.meetingTranslationRecordingState = .error
                handleMeetingTranslationStateChange(.error)
            }
            return
        }

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

            // Set microphone device for mixed recording
            if let deviceID = appState.selectedDeviceID {
                meetingRecorderService.microphoneDevice = audioDeviceManager.device(for: deviceID)
            } else {
                meetingRecorderService.microphoneDevice = audioDeviceManager.getCurrentDefaultDevice()
            }

            try await meetingRecorderService.startRecording()
            Log.app.info("Meeting translation recording started")

            // Hardcoded: stream realtime meeting translation (EN -> UK)
            let store = await setupRealtimeMeetingTranslation(apiKey: apiKey)

            // Only set recording state AFTER confirmed working
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

    @available(macOS 13.0, *)
    private func setupRealtimeMeetingTranslation(apiKey: String) async -> LiveTranscriptStore {
        let store = await MainActor.run { LiveTranscriptStore() }

        let rtService = realtimeTranscriptionService

        // Stream the exact same mixed mono audio that is written to fallback WAV.
        meetingRecorderService.onRealtimeAudioData = { [weak rtService] pcmData in
            rtService?.sendAudioData(pcmData)
        }

        // Wire token callbacks
        rtService.onTokensReceived = { [weak self, weak store] tokens in
            guard let self else { return }
            let translatedTokens = self.filterMeetingTranslatedTokens(tokens)
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

        rtService.onError = { error in
            Log.transcription.error("Realtime meeting translation error: \(error.localizedDescription)")
            // Don't stop recording — file recording continues independently
        }

        // Connect WebSocket (recording continues even if translation socket is unavailable)
        do {
            var languageHints = SettingsStorage.shared.sonioxLanguageHints
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            if !languageHints.contains("en") {
                languageHints.append("en")
            }
            if !languageHints.contains("uk") {
                languageHints.append("uk")
            }

            try await rtService.connect(
                apiKey: apiKey,
                languageHints: languageHints,
                strictLanguageHints: SettingsStorage.shared.sonioxLanguageHintsStrict,
                audioConfig: .defaultPCM16kMono,
                translationConfig: RealtimeTranslationConfig(
                    mode: .oneWay(sourceLanguage: "en", targetLanguage: "uk")
                )
            )
            await MainActor.run {
                store.isActive = true
            }
            NSLog("[Transcription] Meeting real-time translation connected successfully (EN -> UK)")
        } catch {
            NSLog("[Transcription] Meeting real-time translation FAILED to connect: %@", error.localizedDescription)
            await MainActor.run {
                store.isActive = true
                store.connectionStatus = .failed(error.localizedDescription)
            }
            // Recording continues — fallback to async translation on stop
        }

        return store
    }

    private func filterMeetingTranslatedTokens(_ tokens: [RealtimeToken]) -> [RealtimeToken] {
        let translatedTokens = tokens.filter { token in
            token.translationStatus?.lowercased() == "translation"
        }
        if !translatedTokens.isEmpty {
            return translatedTokens
        }

        // Fallback for payloads that do not include translation_status.
        let hasTranslationStatus = tokens.contains { $0.translationStatus != nil }
        if !hasTranslationStatus {
            return tokens
        }

        return []
    }

    // MARK: - Stop Meeting Translation Recording

    func stopMeetingTranslationRecording() async {
        Log.app.info("stopMeetingTranslationRecording: BEGIN")

        guard #available(macOS 13.0, *) else { return }

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
            await realtimeTranscriptionService.finalize()
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

        do {
            guard let audioURL = try await meetingRecorderService.stopRecording() else {
                throw MeetingRecorderError.recordingFailed
            }
            capturedAudioURL = audioURL

            Log.app.info("Meeting translation recording stopped")

            // Check if we have real-time translated text
            let realtimeText = await MainActor.run { store?.finalTranscriptText ?? "" }

            let text: String
            if !realtimeText.isEmpty {
                // Use real-time translation
                text = realtimeText
                Log.app.info("Using real-time meeting translation (\(realtimeText.count) chars)")
            } else {
                // Fallback: upload WAV to async REST API translation
                Log.app.info("No real-time meeting translation, falling back to async API...")
                let audioData = try await loadAudioData(from: audioURL)
                Log.app.info("Meeting translation recording size = \(audioData.count) bytes")

                guard let apiKey = KeychainManager.shared.getSonioxAPIKey(), !apiKey.isEmpty else {
                    throw TranscriptionError.noAPIKey
                }
                transcriptionService.apiKey = apiKey
                text = try await transcriptionService.translateAndTranscribe(audioData: audioData, targetLanguage: "uk")
                Log.app.info("Async meeting translation received: \(text.prefix(100))...")
            }

            clipboardService.copy(text: text)
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

            // Update state to success
            await MainActor.run {
                appState.lastTranscription = text
                appState.meetingTranslationRecordingState = .success
                appState.meetingTranslationRecordingStartTime = nil
                handleMeetingTranslationStateChange(.success)
            }
            Log.app.info("stopMeetingTranslationRecording: SUCCESS")

            // Save to recordings library (copies file before we delete temp)
            let duration = recordingStartTime.map { stopTime.timeIntervalSince($0) } ?? 0
            RecordingsLibraryStorage.shared.saveRecording(
                audioURL: audioURL,
                type: .meeting,
                duration: duration,
                transcriptionText: text
            )

            // Optional operations run after state change (non-blocking for UI)
            if SettingsStorage.shared.playSoundOnCompletion {
                NSSound(named: .init("Funk"))?.play()
            }

            // Clear recovery state on success
            RecoveryStateManager.shared.clearState()

            // Clean up temp file (after library save copied it)
            try? FileManager.default.removeItem(at: audioURL)

        } catch {
            Log.app.error("Meeting translation failed: \(error)")

            // Save recording without translation so user can process later
            if let audioURL = capturedAudioURL {
                let duration = recordingStartTime.map { stopTime.timeIntervalSince($0) } ?? 0
                RecordingsLibraryStorage.shared.saveRecording(
                    audioURL: audioURL,
                    type: .meeting,
                    duration: duration
                )
                // Clean up temp file after library save
                try? FileManager.default.removeItem(at: audioURL)
                RecoveryStateManager.shared.clearState()
            }

            await MainActor.run {
                appState.errorMessage = error.localizedDescription
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

        // On first escape: show confirmation notification
        escapeService.onFirstEscape = { [weak self] in
            NotchManager.shared.showInfo(
                message: "Press ESC again to cancel",
                duration: 1.5
            )

            // Resume showing recording state after info disappears
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(1.6))
                guard let self,
                      self.appState.meetingTranslationRecordingState == .recording else { return }
                NotchManager.shared.startRecording(mode: .meetingTranslation)
            }
        }

        // On second escape (confirmed cancel): cancel recording
        escapeService.onCancel = { [weak self] in
            guard #available(macOS 13.0, *) else { return }
            Task { @MainActor in
                await self?.cancelMeetingTranslationRecording()
                NotchManager.shared.showInfo(message: "Recording cancelled")
            }
        }

        escapeService.activate()
    }

}
