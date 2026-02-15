import AppKit
import Combine
import Foundation

@available(macOS 13.0, *)
actor RealtimeTranslationAccumulator {
    private var finalOriginalText: String = ""
    private var finalTranslatedText: String = ""

    func process(tokens: [RealtimeToken]) {
        let finalTokens = tokens.filter(\.isFinal)
        guard !finalTokens.isEmpty else { return }

        for token in finalTokens {
            let status = token.translationStatus?.lowercased()
            switch status {
            case "translation":
                finalTranslatedText += token.text
            case "transcription", "source", "original", "none", nil:
                finalOriginalText += token.text
            default:
                finalOriginalText += token.text
            }
        }
    }

    func bestText() -> String {
        let translated = finalTranslatedText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !translated.isEmpty {
            return translated
        }

        return finalOriginalText.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Translation Recording (EN <-> UK)

extension AppDelegate {
    @objc func toggleTranslationRecording() {
        Log.app.info("toggleTranslationRecording called, current state: \(self.appState.translationRecordingState)")
        Task {
            await self.performToggleTranslationRecording()
        }
    }

    func performToggleTranslationRecording() async {
        switch appState.translationRecordingState {
        case .idle:
            await startTranslationRecording()
        case .recording:
            await stopTranslationRecording()
        case .processing:
            Log.app.info("Translation state is processing, canceling...")
            await cancelTranslationRecording()
        default:
            Log.app.info("Translation state is \(self.appState.translationRecordingState), ignoring toggle")
        }
    }

    func cancelTranslationRecording() async {
        Log.app.info("cancelTranslationRecording: BEGIN")

        // Stop audio level piping
        audioLevelCancellable?.cancel()
        audioLevelCancellable = nil

        // Stop realtime translation session (if active)
        _ = await stopTranslationRealtimeSession(finalize: false)

        // Deactivate escape cancel handler
        EscapeCancelService.shared.deactivate()

        // Cancel audio recorder
        audioRecorder.cancelRecording()

        // End App Nap prevention
        if let token = translationActivityToken {
            ProcessInfo.processInfo.endActivity(token)
            translationActivityToken = nil
        }

        // Clear recovery state
        RecoveryStateManager.shared.clearState()

        // Reset push-to-talk hands-free mode if active
        translationPushToTalkService.resetHandsFreeMode()

        // Reset state to idle
        await MainActor.run {
            appState.translationRecordingState = .idle
            appState.translationRecordingStartTime = nil
            handleTranslationStateChange(.idle)
        }

        Log.app.info("cancelTranslationRecording: END")
    }

    func startTranslationRecordingIfIdle() async {
        guard appState.translationRecordingState == .idle else {
            Log.app.info("startTranslationRecordingIfIdle: Not idle, ignoring")
            return
        }
        await startTranslationRecording()
    }

    func stopTranslationRecordingIfRecording() async {
        guard appState.translationRecordingState == .recording else {
            Log.app.info("stopTranslationRecordingIfRecording: Not recording, ignoring")
            return
        }
        await stopTranslationRecording()
    }

    func startTranslationRecording() async {
        Log.app.info("startTranslationRecording: BEGIN")

        guard canStartRecording(kind: .translation) else {
            Log.app.info("startTranslationRecording: blocked by another active recording mode")
            return
        }

        // Request microphone permission on-demand
        let micGranted = await PermissionManager.shared.ensureMicrophonePermission()
        appState.microphonePermissionGranted = micGranted

        guard micGranted else {
            Log.app.warning("startTranslationRecording: Microphone permission not granted")
            await MainActor.run {
                appState.errorMessage = "Microphone access required"
                appState.translationRecordingState = .error
                handleTranslationStateChange(.error)
            }
            return
        }

        // Translation always uses Soniox (Cloud)
        guard let apiKey = KeychainManager.shared.getSonioxAPIKey(), !apiKey.isEmpty else {
            Log.app.warning("startTranslationRecording: No API key found")
            await MainActor.run {
                appState.errorMessage = "Translation requires a Soniox API key. Add one in Settings."
                appState.translationRecordingState = .error
                handleTranslationStateChange(.error)
            }
            return
        }
        Log.app.info("startTranslationRecording: Soniox API key found")
        translationRealtimeSessionEnabled = false

        // Determine device with fallback to system default
        var device: AudioDevice?

        if let deviceID = appState.selectedDeviceID {
            // Refresh device list to ensure we have current state
            audioDeviceManager.refreshDevices()

            if audioDeviceManager.isDeviceAvailable(deviceID) {
                device = audioDeviceManager.device(for: deviceID)
                Log.app.info("startTranslationRecording: Using selected device: \(device?.name ?? "none")")
            } else {
                // Selected device is no longer available - fallback to system default
                Log.app.warning("startTranslationRecording: Selected device (ID: \(deviceID)) not available, falling back to default")
                device = audioDeviceManager.getCurrentDefaultDevice()
                Log.app.info("startTranslationRecording: Fallback to default device: \(device?.name ?? "none")")
            }
        } else {
            // No device selected - use system default
            Log.app.info("startTranslationRecording: No device selected, using system default")
            device = audioDeviceManager.getCurrentDefaultDevice()
        }

        // If still no device available, try last resort or show error
        if device == nil {
            if audioDeviceManager.availableDevices.isEmpty {
                Log.app.error("startTranslationRecording: No audio input devices available")
                await MainActor.run {
                    appState.errorMessage = "No microphone found. Please connect a microphone."
                    appState.translationRecordingState = .error
                    handleTranslationStateChange(.error)
                }
                return
            }
            // Last resort: pick first available device
            device = audioDeviceManager.availableDevices.first
            Log.app.info("startTranslationRecording: Using first available device: \(device?.name ?? "none")")
        }

        Log.app.info("startTranslationRecording: Setting state to processing")

        // Prevent App Nap during translation recording
        translationActivityToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "Translation recording in progress"
        )

        // Show processing state while initializing audio (before we confirm it works)
        await MainActor.run {
            appState.translationRecordingState = .processing
            handleTranslationStateChange(.processing)
        }

        do {
            Log.app.info("startTranslationRecording: Starting audio recording")
            try await audioRecorder.startRecording(device: device)
            Log.app.info("startTranslationRecording: Recording started successfully")

            // Only set recording state AFTER audio engine is confirmed working
            await MainActor.run {
                appState.translationRecordingState = .recording
                appState.translationRecordingStartTime = Date()
                handleTranslationStateChange(.recording)

                // Pipe audio level to notch
                audioLevelCancellable = audioRecorder.$audioLevel
                    .receive(on: DispatchQueue.main)
                    .sink { level in
                        NotchManager.shared.audioLevel = level
                    }
            }

            // Activate escape cancel handler
            await MainActor.run {
                setupTranslationEscapeCancelHandler()
            }

            // Optional websocket mode: realtime cloud transcription + translation
            await setupRealtimeTranslationIfNeeded(apiKey: apiKey)
        } catch let error as AudioTimeoutError {
            // Audio hardware timed out - likely coreaudiod is unresponsive or device is unavailable
            Log.app.error("startTranslationRecording: TIMEOUT - \(error.localizedDescription)")

            // End App Nap prevention
            if let token = translationActivityToken {
                ProcessInfo.processInfo.endActivity(token)
                translationActivityToken = nil
            }

            // Show specific error message for timeout
            await MainActor.run {
                appState.errorMessage = error.localizedDescription
                appState.translationRecordingState = .error
                appState.translationRecordingStartTime = nil
                handleTranslationStateChange(.error)
            }

            return
        } catch {
            // Handle any other errors during recording start
            Log.app.error("startTranslationRecording: ERROR - \(error.localizedDescription)")

            // End App Nap prevention
            if let token = translationActivityToken {
                ProcessInfo.processInfo.endActivity(token)
                translationActivityToken = nil
            }

            await MainActor.run {
                appState.errorMessage = error.localizedDescription
                appState.translationRecordingState = .error
                appState.translationRecordingStartTime = nil
                handleTranslationStateChange(.error)
            }
            return
        }

        // Save recovery state in case of crash
        if let path = audioRecorder.currentRecordingPath {
            let state = RecoveryState(
                tempFilePath: path,
                startTime: Date(),
                recordingType: .translation
            )
            RecoveryStateManager.shared.saveState(state)
        }
    }

    func stopTranslationRecording() async {
        Log.app.info("stopTranslationRecording: BEGIN")

        // Stop audio level piping
        audioLevelCancellable?.cancel()
        audioLevelCancellable = nil

        // Deactivate escape cancel handler
        EscapeCancelService.shared.deactivate()

        // Capture recording start time for duration calculation
        let recordingStartTime = appState.translationRecordingStartTime

        // Capture stop time immediately for accurate duration
        let stopTime = Date()

        await MainActor.run {
            appState.translationRecordingState = .processing
            handleTranslationStateChange(.processing)
        }

        // Capture audio data first so it's available in both success and error paths
        var capturedAudioData: Data?

        do {
            Log.app.info("stopTranslationRecording: Stopping audio recorder")
            let audioData = try await audioRecorder.stopRecording()
            capturedAudioData = audioData
            Log.app.info("stopTranslationRecording: Got audio data, size = \(audioData.count) bytes")

            // If websocket mode produced translated text, use it.
            let realtimeText = await stopTranslationRealtimeSession(finalize: true)

            let text: String
            if !realtimeText.isEmpty {
                text = realtimeText
                Log.app.info("stopTranslationRecording: Using realtime translation (\(realtimeText.count) chars)")
            } else {
                // Fallback: async cloud translation
                var service: TranscriptionServiceProtocol = transcriptionService
                guard let apiKey = KeychainManager.shared.getSonioxAPIKey() else {
                    Log.app.error("stopTranslationRecording: No API key!")
                    throw TranscriptionError.noAPIKey
                }
                service.apiKey = apiKey

                Log.app.info("stopTranslationRecording: Calling async Soniox translation service (fallback)")
                text = try await service.translateAndTranscribe(audioData: audioData)
            }
            Log.app.info("stopTranslationRecording: Translation received: \(text.prefix(50))...")

            clipboardService.copy(text: text)
            Log.app.info("stopTranslationRecording: Text copied to clipboard")

            if SettingsStorage.shared.autoPaste {
                Log.app.info("stopTranslationRecording: Auto-pasting")
                do {
                    try await clipboardService.paste()
                } catch ClipboardError.accessibilityNotGranted {
                    Log.app.warning("stopTranslationRecording: Accessibility permission needed")
                    PermissionManager.shared.showPermissionAlert(for: .accessibility)
                } catch {
                    Log.app.error("stopTranslationRecording: Paste failed - \(error.localizedDescription)")
                }
            }

            // Update state to success IMMEDIATELY after text is available
            // This ensures the UI shows checkmark right when user can work with the text
            await MainActor.run {
                appState.lastTranscription = text
                appState.isEmptyTranscription = false
                appState.translationRecordingState = .success
                appState.translationRecordingStartTime = nil
                handleTranslationStateChange(.success)
            }
            Log.app.info("stopTranslationRecording: SUCCESS")

            // Save to recordings library
            let duration = recordingStartTime.map { stopTime.timeIntervalSince($0) } ?? 0
            RecordingsLibraryStorage.shared.saveRecording(
                audioData: audioData,
                type: .translation,
                duration: duration,
                transcriptionText: text
            )

            // Optional operations run after state change (non-blocking for UI)
            if SettingsStorage.shared.playSoundOnCompletion {
                Log.app.info("stopTranslationRecording: Playing sound")
                NSSound(named: .init("Funk"))?.play()
            }

            // Clear recovery state on success
            RecoveryStateManager.shared.clearState()

        } catch {
            _ = await stopTranslationRealtimeSession(finalize: false)
            Log.app.error("stopTranslationRecording: ERROR - \(error.localizedDescription)")
            let isEmptyTranscription: Bool = {
                guard case .emptyTranscription = error as? TranscriptionError else { return false }
                return true
            }()

            // Save recording without transcription so user can process later
            if let audioData = capturedAudioData {
                let duration = recordingStartTime.map { stopTime.timeIntervalSince($0) } ?? 0
                RecordingsLibraryStorage.shared.saveRecording(
                    audioData: audioData,
                    type: .translation,
                    duration: duration
                )
                RecoveryStateManager.shared.clearState()
            }

            await MainActor.run {
                appState.errorMessage = error.localizedDescription
                appState.isEmptyTranscription = isEmptyTranscription
                appState.translationRecordingState = .error
                appState.translationRecordingStartTime = nil
                handleTranslationStateChange(.error)
            }
        }

        // End App Nap prevention
        if let token = translationActivityToken {
            ProcessInfo.processInfo.endActivity(token)
            translationActivityToken = nil
        }

        Log.app.info("stopTranslationRecording: END")
    }

    // MARK: - Realtime Translation (WebSocket)

    private func setupRealtimeTranslationIfNeeded(apiKey: String) async {
        guard SettingsStorage.shared.translationRealtimeSocketEnabled else {
            audioRecorder.onRealtimeAudioData = nil
            translationRealtimeSessionEnabled = false
            translationRealtimeAccumulator = nil
            return
        }

        let pair = translationLanguagePair()
        let accumulator = RealtimeTranslationAccumulator()
        translationRealtimeAccumulator = accumulator

        let rtService = realtimeTranscriptionService
        audioRecorder.onRealtimeAudioData = { [weak rtService] pcmData in
            rtService?.sendAudioData(pcmData)
        }

        rtService.onTokensReceived = { [weak accumulator] tokens in
            guard let accumulator else { return }
            Task {
                await accumulator.process(tokens: tokens)
            }
        }

        rtService.onConnectionStatusChanged = { status in
            Log.transcription.info("Translation RT status: \(String(describing: status))")
        }

        rtService.onError = { error in
            Log.transcription.error("Translation RT error: \(error.localizedDescription)")
        }

        do {
            try await rtService.connect(
                apiKey: apiKey,
                languageHints: [pair.languageA, pair.languageB],
                strictLanguageHints: SettingsStorage.shared.sonioxLanguageHintsStrict,
                audioConfig: .defaultPCM16kMono,
                translationConfig: RealtimeTranslationConfig(
                    mode: .twoWay(languageA: pair.languageA, languageB: pair.languageB)
                )
            )

            translationRealtimeSessionEnabled = true
            Log.transcription.info("Translation RT connected (\(pair.languageA) <-> \(pair.languageB))")
        } catch {
            audioRecorder.onRealtimeAudioData = nil
            translationRealtimeSessionEnabled = false
            translationRealtimeAccumulator = nil
            Log.transcription.warning(
                "Translation RT unavailable (\(error.localizedDescription)); fallback to async translation will be used"
            )
        }
    }

    private func stopTranslationRealtimeSession(finalize: Bool) async -> String {
        audioRecorder.onRealtimeAudioData = nil

        let accumulator = translationRealtimeAccumulator
        let wasEnabled = translationRealtimeSessionEnabled

        defer {
            translationRealtimeSessionEnabled = false
            translationRealtimeAccumulator = nil
            realtimeTranscriptionService.onTokensReceived = nil
            realtimeTranscriptionService.onError = nil
            realtimeTranscriptionService.onConnectionStatusChanged = nil
        }

        guard wasEnabled else {
            return ""
        }

        if finalize {
            await realtimeTranscriptionService.finalize()
        }
        await realtimeTranscriptionService.disconnect()

        let text = await accumulator?.bestText() ?? ""
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func translationLanguagePair(targetLanguage: String = "uk") -> (languageA: String, languageB: String) {
        if targetLanguage == "en" {
            let primary = SettingsStorage.shared.favoriteLanguages.first(where: { $0 != "en" }) ?? "uk"
            return (primary, "en")
        }
        return ("en", targetLanguage)
    }

    // MARK: - Escape Cancel Handler

    private func setupTranslationEscapeCancelHandler() {
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
                      self.appState.translationRecordingState == .recording else { return }
                NotchManager.shared.startRecording(mode: .translation(languagePair: "EN <-> UK"))
            }
        }

        // On second escape (confirmed cancel): cancel recording
        escapeService.onCancel = { [weak self] in
            Task { @MainActor in
                await self?.cancelTranslationRecording()
                NotchManager.shared.showInfo(message: "Recording cancelled")
            }
        }

        escapeService.activate()
    }
}
