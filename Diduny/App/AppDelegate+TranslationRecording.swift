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

    func markSegmentBoundary() {
        // No-op: pause-based formatting removed
    }

    func bestText() -> String {
        let translated = finalTranslatedText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !translated.isEmpty {
            return translated
        }

        return finalOriginalText.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Translation Recording

extension AppDelegate {
    @objc func toggleTranslationRecording() {
        Log.app.info("toggleTranslationRecording called, current state: \(self.appState.translationRecordingState)")
        translationPipelineTask?.cancel()
        translationPipelineTask = Task {
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
            await cancelTranslationRecording(cancelTask: false)
        default:
            Log.app.info("Translation state is \(self.appState.translationRecordingState), ignoring toggle")
        }
    }

    func cancelTranslationRecording(cancelTask: Bool = true) async {
        Log.app.info("cancelTranslationRecording: BEGIN")

        // Cancel any in-flight pipeline task (skip when called from within the task itself)
        if cancelTask {
            translationPipelineTask?.cancel()
        }
        translationPipelineTask = nil

        let recordingStartTime = appState.translationRecordingStartTime
        let stopTime = Date()

        // Stop audio level piping
        audioLevelCancellable?.cancel()
        audioLevelCancellable = nil

        // Stop realtime translation session (if active)
        _ = await stopTranslationRealtimeSession(finalize: false)

        // Deactivate escape cancel handler
        EscapeCancelService.shared.deactivate()

        if SettingsStorage.shared.escapeCancelSaveAudio, audioRecorder.isRecording {
            do {
                let audioData = try await audioRecorder.stopRecording()
                let duration = recordingStartTime.map { stopTime.timeIntervalSince($0) } ?? 0
                RecordingsLibraryStorage.shared.saveRecording(
                    audioData: audioData,
                    type: .translation,
                    duration: duration
                )
                Log.app.info("cancelTranslationRecording: audio saved after cancel")
            } catch {
                Log.app.warning("cancelTranslationRecording: failed to save audio on cancel - \(error.localizedDescription)")
                audioRecorder.cancelRecording()
            }
        } else {
            // Cancel audio recorder without persisting
            audioRecorder.cancelRecording()
        }

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

        // Provider-specific validation for Local mode
        if SettingsStorage.shared.transcriptionProvider == .local {
            guard WhisperModelManager.shared.selectedModel() != nil else {
                Log.app.warning("startTranslationRecording: No Whisper model selected")
                await MainActor.run {
                    appState.errorMessage = "No Whisper model downloaded. Please download one in Settings."
                    appState.translationRecordingState = .error
                    handleTranslationStateChange(.error)
                }
                return
            }
        }
        Log.app.info("startTranslationRecording: Provider ready")
        translationRealtimeSessionEnabled = false

        // Determine device with fallback to best available
        var device: AudioDevice?

        if let selectedUID = appState.selectedDeviceUID {
            let (validDevice, didFallback) = audioDeviceManager.getValidDevice(selectedUID: selectedUID)
            device = validDevice

            if didFallback {
                NSLog("[Diduny] startTranslationRecording: Selected device (UID: %@) not available, using %@", selectedUID, device?.name ?? "default")
            } else {
                NSLog("[Diduny] startTranslationRecording: Using selected device: %@", device?.name ?? "none")
            }
        } else {
            NSLog("[Diduny] startTranslationRecording: No device selected, using best available")
            device = audioDeviceManager.bestDevice() ?? audioDeviceManager.getCurrentDefaultDevice()
        }

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
            // Set up realtime callback BEFORE starting recorder (AudioRecorderService
            // snapshots onRealtimeAudioData at start time). WebSocket connects in background.
            setupRealtimeTranslationIfNeeded()

            Log.app.info("startTranslationRecording: Starting audio recording")
            try await audioRecorder.startRecording(device: device)
            Log.app.info("startTranslationRecording: Recording started successfully")

            // Only set recording state AFTER audio engine is confirmed working
            guard appState.translationRecordingState == .processing else {
                Log.app.warning("startTranslationRecording: state changed during init (now \(self.appState.translationRecordingState)), aborting")
                audioRecorder.cancelRecording()
                _ = await stopTranslationRealtimeSession(finalize: false)
                if let token = translationActivityToken {
                    ProcessInfo.processInfo.endActivity(token)
                    translationActivityToken = nil
                }
                return
            }
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
        } catch let error as AudioTimeoutError {
            // Audio hardware timed out - likely coreaudiod is unresponsive or device is unavailable
            Log.app.error("startTranslationRecording: TIMEOUT - \(error.localizedDescription)")

            _ = await stopTranslationRealtimeSession(finalize: false)

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

            _ = await stopTranslationRealtimeSession(finalize: false)

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
        let recordingId = UUID()

        do {
            Log.app.info("stopTranslationRecording: Stopping audio recorder")
            let audioData = try await audioRecorder.stopRecording()
            capturedAudioData = audioData
            Log.app.info("stopTranslationRecording: Got audio data, size = \(audioData.count) bytes")

            let realtimeResult = await stopTranslationRealtimeSession(finalize: true)

            let text: String
            if !realtimeResult.text.isEmpty {
                text = realtimeResult.text
                Log.app.info("stopTranslationRecording: Using realtime translation (\(text.count) chars)")
            } else if SettingsStorage.shared.transcriptionProvider == .local {
                // Local Whisper — no WebSocket, transcribe from audio
                text = try await whisperTranscriptionService.translateAndTranscribe(audioData: audioData)
                Log.app.info("stopTranslationRecording: Local Whisper translation (\(text.count) chars)")
            } else if let connectionError = translationRealtimeConnectionError {
                throw TranscriptionError.cloudConnectionFailed(connectionError)
            } else {
                throw TranscriptionError.emptyTranscription
            }
            Log.app.info("stopTranslationRecording: Translation received (\(text.count) chars)")

            guard appState.translationRecordingState == .processing else {
                Log.app.warning("stopTranslationRecording: state changed during processing (now \(self.appState.translationRecordingState)), dropping result")
                return
            }

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

            await MainActor.run {
                appState.lastTranscription = text
                appState.isEmptyTranscription = false
                appState.translationRecordingState = .success
                appState.translationRecordingStartTime = nil
                handleTranslationStateChange(.success)
            }
            Log.app.info("stopTranslationRecording: SUCCESS")

            let duration = recordingStartTime.map { stopTime.timeIntervalSince($0) } ?? 0
            RecordingsLibraryStorage.shared.saveRecording(
                id: recordingId,
                audioData: audioData,
                type: .translation,
                duration: duration,
                transcriptionText: text
            )

            if SettingsStorage.shared.playSoundOnCompletion {
                Log.app.info("stopTranslationRecording: Playing sound")
                NSSound(named: .init("Funk"))?.play()
            }

            RecoveryStateManager.shared.clearState()

        } catch is CancellationError {
            _ = await stopTranslationRealtimeSession(finalize: false)
            Log.app.info("stopTranslationRecording: Cancelled")
            await MainActor.run {
                appState.translationRecordingState = .idle
                appState.translationRecordingStartTime = nil
                handleTranslationStateChange(.idle)
            }
            return
        } catch {
            _ = await stopTranslationRealtimeSession(finalize: false)
            Log.app.error("stopTranslationRecording: ERROR - \(error.localizedDescription)")
            let isEmptyTranscription: Bool = {
                guard case .emptyTranscription = error as? TranscriptionError else { return false }
                return true
            }()

            if let audioData = capturedAudioData {
                let duration = recordingStartTime.map { stopTime.timeIntervalSince($0) } ?? 0
                RecordingsLibraryStorage.shared.saveRecording(
                    id: recordingId,
                    audioData: audioData,
                    type: .translation,
                    duration: duration
                )
                RecoveryStateManager.shared.clearState()
            }

            guard appState.translationRecordingState == .processing else {
                Log.app.warning("stopTranslationRecording: state changed during processing (now \(self.appState.translationRecordingState)), dropping error")
                return
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

    private func setupRealtimeTranslationIfNeeded() {
        guard SettingsStorage.shared.transcriptionProvider == .cloud else {
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

        rtService.onSegmentBoundary = { [weak accumulator] _ in
            guard let accumulator else { return }
            Task {
                await accumulator.markSegmentBoundary()
            }
        }

        rtService.onError = { error in
            Log.transcription.error("Translation RT error: \(error.localizedDescription)")
        }

        translationRealtimeConnectionError = nil

        // Connect WebSocket in background — don't block recording start
        Task {
            do {
                try await rtService.connect(
                    languageHints: [pair.languageA, pair.languageB],
                    strictLanguageHints: true,
                    audioConfig: .defaultPCM16kMono,
                    translationConfig: RealtimeTranslationConfig(
                        mode: .twoWay(languageA: pair.languageA, languageB: pair.languageB)
                    ),
                )

                await MainActor.run {
                    self.translationRealtimeSessionEnabled = true
                }
                Log.transcription.info("Translation RT connected (\(pair.languageA) <-> \(pair.languageB))")
            } catch {
                await MainActor.run {
                    self.audioRecorder.onRealtimeAudioData = nil
                    self.translationRealtimeSessionEnabled = false
                    self.translationRealtimeAccumulator = nil
                    self.translationRealtimeConnectionError = error.localizedDescription
                }
                Log.transcription.warning(
                    "Translation RT connection failed: \(error.localizedDescription)"
                )
            }
        }
    }

    private func stopTranslationRealtimeSession(finalize: Bool) async -> (text: String, didReceiveFinalization: Bool) {
        audioRecorder.onRealtimeAudioData = nil

        let accumulator = translationRealtimeAccumulator
        let wasEnabled = translationRealtimeSessionEnabled
        var didReceiveFinalization = false

        defer {
            translationRealtimeSessionEnabled = false
            translationRealtimeAccumulator = nil
            realtimeTranscriptionService.onTokensReceived = nil
            realtimeTranscriptionService.onError = nil
            realtimeTranscriptionService.onConnectionStatusChanged = nil
            realtimeTranscriptionService.onSegmentBoundary = nil
        }

        guard wasEnabled else {
            return ("", false)
        }

        if finalize {
            didReceiveFinalization = await realtimeTranscriptionService.finalize()
        }
        await realtimeTranscriptionService.disconnect()

        let text = await accumulator?.bestText() ?? ""
        return (text.trimmingCharacters(in: .whitespacesAndNewlines), didReceiveFinalization)
    }

    private func translationLanguagePair() -> (languageA: String, languageB: String) {
        return (
            SettingsStorage.shared.translationLanguageA,
            SettingsStorage.shared.translationLanguageB
        )
    }

    // MARK: - Escape Cancel Handler

    private func setupTranslationEscapeCancelHandler() {
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
                      self.appState.translationRecordingState == .recording else { return }
                NotchManager.shared.startRecording(mode: .translation(languagePair: self.translationPairLabel))
            }
        }

        // On second shortcut press (confirmed cancel): cancel recording
        escapeService.onCancel = { [weak self] in
            Task { @MainActor in
                let shouldSaveAudio = SettingsStorage.shared.escapeCancelSaveAudio
                await self?.cancelTranslationRecording()
                let message = shouldSaveAudio ? "Recording cancelled and saved" : "Recording cancelled"
                NotchManager.shared.showInfo(message: message)
            }
        }

        escapeService.activate()
    }

}
