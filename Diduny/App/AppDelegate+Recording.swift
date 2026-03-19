import AppKit
import Combine
import Foundation

@available(macOS 13.0, *)
actor RealtimeVoiceAccumulator {
    private var finalText: String = ""

    func process(tokens: [RealtimeToken]) {
        let finalTokens = tokens.filter(\.isFinal)
        guard !finalTokens.isEmpty else { return }

        for token in finalTokens {
            finalText += token.text
        }
    }

    func markSegmentBoundary() {
        // No-op: pause-based formatting removed
    }

    func bestText() -> String {
        finalText.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Recording Actions

extension AppDelegate {
    @objc func toggleRecording() {
        Log.app.info("toggleRecording called, current state: \(self.appState.recordingState)")
        voicePipelineTask?.cancel()
        voicePipelineTask = Task {
            await self.performToggleRecording()
        }
    }

    func performToggleRecording() async {
        Log.app.info("performToggleRecording: state = \(self.appState.recordingState)")
        switch appState.recordingState {
        case .idle:
            Log.app.info("State is idle, starting recording...")
            await startRecording()
        case .recording:
            Log.app.info("State is recording, stopping recording...")
            await stopRecording()
        case .processing:
            Log.app.info("State is processing, canceling...")
            await cancelRecording(cancelTask: false)
        default:
            Log.app.info("State is \(self.appState.recordingState), ignoring toggle")
        }
    }

    func cancelRecording(cancelTask: Bool = true) async {
        Log.app.info("cancelRecording: BEGIN")

        // Cancel any in-flight pipeline task (skip when called from within the task itself)
        if cancelTask {
            voicePipelineTask?.cancel()
        }
        voicePipelineTask = nil

        let recordingStartTime = appState.recordingStartTime
        let stopTime = Date()

        // Stop audio level piping
        audioLevelCancellable?.cancel()
        audioLevelCancellable = nil

        // Stop realtime transcription session (if active)
        _ = await stopVoiceRealtimeSession(finalize: false)

        // Deactivate escape cancel handler
        EscapeCancelService.shared.deactivate()

        if SettingsStorage.shared.escapeCancelSaveAudio, audioRecorder.isRecording {
            do {
                let audioData = try await audioRecorder.stopRecording()
                let duration = recordingStartTime.map { stopTime.timeIntervalSince($0) } ?? 0
                RecordingsLibraryStorage.shared.saveRecording(
                    audioData: audioData,
                    type: .voice,
                    duration: duration
                )
                Log.app.info("cancelRecording: audio saved after cancel")
            } catch {
                Log.app.warning("cancelRecording: failed to save audio on cancel - \(error.localizedDescription)")
                audioRecorder.cancelRecording()
            }
        } else {
            // Cancel audio recorder without persisting
            audioRecorder.cancelRecording()
        }

        // End App Nap prevention
        if let token = recordingActivityToken {
            ProcessInfo.processInfo.endActivity(token)
            recordingActivityToken = nil
        }

        // Clear recovery state
        RecoveryStateManager.shared.clearState()

        // Reset push-to-talk hands-free mode if active
        pushToTalkService.resetHandsFreeMode()

        // Reset state to idle
        await MainActor.run {
            appState.recordingState = .idle
            appState.recordingStartTime = nil
            appState.deviceFallbackWarning = nil
            handleRecordingStateChange(.idle)
        }

        Log.app.info("cancelRecording: END")
    }

    func startRecordingIfIdle() async {
        guard appState.recordingState == .idle else {
            Log.app.info("startRecordingIfIdle: Not idle, ignoring")
            return
        }
        await startRecording()
    }

    func stopRecordingIfRecording() async {
        guard appState.recordingState == .recording else {
            Log.app.info("stopRecordingIfRecording: Not recording, ignoring")
            return
        }
        await stopRecording()
    }

    func startRecording() async {
        Log.app.info("startRecording: BEGIN")

        guard canStartRecording(kind: .voice) else {
            Log.app.info("startRecording: blocked by another active recording mode")
            return
        }

        // Request microphone permission on-demand
        let micGranted = await PermissionManager.shared.ensureMicrophonePermission()
        appState.microphonePermissionGranted = micGranted

        guard micGranted else {
            Log.app.warning("startRecording: Microphone permission not granted")
            await MainActor.run {
                appState.errorMessage = "Microphone access required"
                appState.recordingState = .error
                handleRecordingStateChange(.error)
            }
            return
        }

        // Provider-specific validation
        switch SettingsStorage.shared.transcriptionProvider {
        case .cloud:
            Log.app.info("startRecording: Cloud provider selected")
        case .local:
            guard WhisperModelManager.shared.selectedModel() != nil else {
                Log.app.warning("startRecording: No Whisper model selected")
                await MainActor.run {
                    appState.errorMessage = "No Whisper model downloaded. Please download one in Settings."
                    appState.recordingState = .error
                    handleRecordingStateChange(.error)
                }
                return
            }
            Log.app.info("startRecording: Whisper model ready")
        }

        // Determine device with fallback to best available
        var device: AudioDevice?

        if let selectedUID = appState.selectedDeviceUID {
            let (validDevice, didFallback) = audioDeviceManager.getValidDevice(selectedUID: selectedUID)
            device = validDevice

            if didFallback {
                Log.app.warning("startRecording: Selected device (UID: \(selectedUID)) unavailable, using \(device?.name ?? "default")")
                if let fallbackName = device?.name {
                    await MainActor.run {
                        appState.deviceFallbackWarning = "Using \(fallbackName)"
                    }
                }
            } else {
                Log.app.info("startRecording: Using selected device: \(device?.name ?? "none")")
            }
        } else {
            Log.app.info("startRecording: No device selected, using best available")
            device = audioDeviceManager.bestDevice() ?? audioDeviceManager.getCurrentDefaultDevice()
        }

        if device == nil {
            if audioDeviceManager.availableDevices.isEmpty {
                Log.app.error("startRecording: No audio input devices available")
                await MainActor.run {
                    appState.errorMessage = "No microphone found. Please connect a microphone."
                    appState.recordingState = .error
                    handleRecordingStateChange(.error)
                }
                return
            }
            device = audioDeviceManager.availableDevices.first
            Log.app.info("startRecording: Using first available device: \(device?.name ?? "none")")
        }

        Log.app.info("startRecording: Setting state to recording")

        // Prevent App Nap during recording
        recordingActivityToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "Voice recording in progress"
        )

        // Show processing state while initializing audio (before we confirm it works)
        await MainActor.run {
            appState.recordingState = .processing
            handleRecordingStateChange(.processing)
        }

        do {
            // Configure realtime websocket BEFORE starting recorder.
            // AudioRecorderService snapshots onRealtimeAudioData at start time.
            await setupVoiceRealtimeTranscriptionIfNeeded()

            Log.app.info("startRecording: Starting audio recording")
            try await audioRecorder.startRecording(device: device)
            Log.app.info("startRecording: Recording started successfully")

            // Only set recording state AFTER audio engine is confirmed working
            guard appState.recordingState == .processing else {
                Log.app.warning("startRecording: state changed during init (now \(self.appState.recordingState)), aborting")
                audioRecorder.cancelRecording()
                _ = await stopVoiceRealtimeSession(finalize: false)
                if let token = recordingActivityToken {
                    ProcessInfo.processInfo.endActivity(token)
                    recordingActivityToken = nil
                }
                return
            }
            await MainActor.run {
                appState.recordingState = .recording
                appState.recordingStartTime = Date()
                handleRecordingStateChange(.recording)

                // Pipe audio level to notch
                audioLevelCancellable = audioRecorder.$audioLevel
                    .receive(on: DispatchQueue.main)
                    .sink { level in
                        NotchManager.shared.audioLevel = level
                    }
            }

            // Activate escape cancel handler
            await MainActor.run {
                setupEscapeCancelHandler()
            }
        } catch let error as AudioTimeoutError {
            // Audio hardware timed out - likely coreaudiod is unresponsive or device is unavailable
            Log.app.error("startRecording: TIMEOUT - \(error.localizedDescription)")

            _ = await stopVoiceRealtimeSession(finalize: false)

            // End App Nap prevention
            if let token = recordingActivityToken {
                ProcessInfo.processInfo.endActivity(token)
                recordingActivityToken = nil
            }

            // Show specific error message for timeout
            await MainActor.run {
                appState.errorMessage = error.localizedDescription
                appState.recordingState = .error
                appState.recordingStartTime = nil
                handleRecordingStateChange(.error)
            }

            return
        } catch {
            // Handle any other errors during recording start
            Log.app.error("startRecording: ERROR - \(error.localizedDescription)")

            _ = await stopVoiceRealtimeSession(finalize: false)

            // End App Nap prevention
            if let token = recordingActivityToken {
                ProcessInfo.processInfo.endActivity(token)
                recordingActivityToken = nil
            }

            await MainActor.run {
                appState.errorMessage = error.localizedDescription
                appState.recordingState = .error
                appState.recordingStartTime = nil
                handleRecordingStateChange(.error)
            }
            return
        }

        // Save recovery state in case of crash
        if let path = audioRecorder.currentRecordingPath {
            let state = RecoveryState(
                tempFilePath: path,
                startTime: Date(),
                recordingType: .voice
            )
            RecoveryStateManager.shared.saveState(state)
        }
    }

    func stopRecording() async {
        Log.app.info("stopRecording: BEGIN")

        // Stop audio level piping
        audioLevelCancellable?.cancel()
        audioLevelCancellable = nil

        // Deactivate escape cancel handler
        EscapeCancelService.shared.deactivate()

        // Capture recording start time for duration calculation
        let recordingStartTime = appState.recordingStartTime

        // Capture stop time immediately for accurate duration
        let stopTime = Date()

        await MainActor.run {
            appState.recordingState = .processing
            handleRecordingStateChange(.processing)
        }

        // Ensure App Nap prevention is always cleaned up
        defer {
            if let token = recordingActivityToken {
                ProcessInfo.processInfo.endActivity(token)
                recordingActivityToken = nil
            }
        }

        // Capture audio data first so it's available in both success and error paths
        var capturedAudioData: Data?
        let recordingId = UUID()

        do {
            Log.app.info("stopRecording: Stopping audio recorder")
            let audioData = try await audioRecorder.stopRecording()
            capturedAudioData = audioData
            Log.app.info("stopRecording: Got audio data, size = \(audioData.count) bytes")

            let realtimeResult = await stopVoiceRealtimeSession(finalize: true)
            let recordingDurationSeconds = recordingStartTime.map { stopTime.timeIntervalSince($0) } ?? 0

            let text: String
            let useRealtimeWithoutFinalize = shouldUseRealtimeFallbackText(
                realtimeResult.text,
                didReceiveFinalization: realtimeResult.didReceiveFinalization,
                recordingDurationSeconds: recordingDurationSeconds
            )

            if useRealtimeWithoutFinalize {
                text = realtimeResult.text
                if realtimeResult.didReceiveFinalization {
                    Log.app.info("stopRecording: Using realtime transcription (\(realtimeResult.text.count) chars)")
                } else {
                    Log.app.warning(
                        "stopRecording: Finalize delayed, using realtime fallback text (\(realtimeResult.text.count) chars)"
                    )
                }
            } else {
                let service = activeTranscriptionService

                if !realtimeResult.didReceiveFinalization {
                    Log.app.warning("stopRecording: Realtime finalize was incomplete, forcing async transcription fallback")
                } else if realtimeResult.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Log.app.info("stopRecording: Realtime transcription empty, using async fallback")
                } else {
                    Log.app.warning(
                        "stopRecording: Realtime finalized text too short (\(realtimeResult.text.count) chars) for \(String(format: "%.2f", recordingDurationSeconds))s recording, using async fallback"
                    )
                }

                do {
                    text = try await service.transcribe(audioData: audioData)
                } catch {
                    if !realtimeResult.text.isEmpty {
                        Log.app.warning(
                            "stopRecording: Async fallback failed, using partial realtime text (\(realtimeResult.text.count) chars)"
                        )
                        text = realtimeResult.text
                    } else {
                        throw error
                    }
                }
            }
            Log.app.info("stopRecording: Transcription received (\(text.count) chars)")

            clipboardService.copy(text: text)
            Log.app.info("stopRecording: Text copied to clipboard")

            if SettingsStorage.shared.autoPaste {
                Log.app.info("stopRecording: Auto-pasting")
                do {
                    try await clipboardService.paste()
                } catch ClipboardError.accessibilityNotGranted {
                    Log.app.warning("stopRecording: Accessibility permission needed")
                    PermissionManager.shared.showPermissionAlert(for: .accessibility)
                } catch {
                    Log.app.error("stopRecording: Paste failed - \(error.localizedDescription)")
                }
            }

            guard appState.recordingState == .processing else {
                Log.app.warning("stopRecording: state changed during processing (now \(self.appState.recordingState)), dropping result")
                return
            }
            await MainActor.run {
                appState.lastTranscription = text
                appState.isEmptyTranscription = false
                appState.deviceFallbackWarning = nil
                appState.recordingState = .success
                appState.recordingStartTime = nil
                handleRecordingStateChange(.success)
            }
            Log.app.info("stopRecording: SUCCESS")

            // Save to recordings library
            let duration = recordingStartTime.map { stopTime.timeIntervalSince($0) } ?? 0
            RecordingsLibraryStorage.shared.saveRecording(
                id: recordingId,
                audioData: audioData,
                type: .voice,
                duration: duration,
                transcriptionText: text
            )

            if SettingsStorage.shared.playSoundOnCompletion {
                Log.app.info("stopRecording: Playing sound")
                NSSound(named: .init("Funk"))?.play()
            }

            RecoveryStateManager.shared.clearState()

        } catch is CancellationError {
            _ = await stopVoiceRealtimeSession(finalize: false)
            Log.app.info("stopRecording: Cancelled")
            await MainActor.run {
                appState.recordingState = .idle
                appState.recordingStartTime = nil
                appState.deviceFallbackWarning = nil
                handleRecordingStateChange(.idle)
            }
            return
        } catch let limitError as TranscriptionError where limitError.isUsageLimitExceeded {
            _ = await stopVoiceRealtimeSession(finalize: false)
            Log.app.warning("stopRecording: Usage limit exceeded, attempting Whisper fallback")

            // Try falling back to local Whisper model
            if let audioData = capturedAudioData, WhisperModelManager.shared.selectedModel() != nil {
                NotchManager.shared.showInfo(message: "Cloud limit reached. Switching to local model.", duration: 2.0)
                do {
                    let text = try await whisperTranscriptionService.transcribe(audioData: audioData)
                    Log.app.info("stopRecording: Whisper fallback succeeded (\(text.count) chars)")
                    clipboardService.copy(text: text)
                    if SettingsStorage.shared.autoPaste {
                        try? await clipboardService.paste()
                    }
                    guard appState.recordingState == .processing else { return }
                    await MainActor.run {
                        appState.lastTranscription = text
                        appState.isEmptyTranscription = false
                        appState.deviceFallbackWarning = nil
                        appState.recordingState = .success
                        appState.recordingStartTime = nil
                        handleRecordingStateChange(.success)
                    }
                    let duration = recordingStartTime.map { stopTime.timeIntervalSince($0) } ?? 0
                    RecordingsLibraryStorage.shared.saveRecording(
                        id: recordingId, audioData: audioData, type: .voice,
                        duration: duration, transcriptionText: text
                    )
                    RecoveryStateManager.shared.clearState()
                    Task { await UsageService.shared.refresh() }
                } catch {
                    Log.app.error("stopRecording: Whisper fallback also failed - \(error.localizedDescription)")
                    guard appState.recordingState == .processing else { return }
                    await MainActor.run {
                        appState.errorMessage = limitError.localizedDescription
                        appState.isEmptyTranscription = false
                        appState.deviceFallbackWarning = nil
                        appState.recordingState = .error
                        appState.recordingStartTime = nil
                        handleRecordingStateChange(.error)
                    }
                }
            } else {
                // No local model available
                if let audioData = capturedAudioData {
                    let duration = recordingStartTime.map { stopTime.timeIntervalSince($0) } ?? 0
                    RecordingsLibraryStorage.shared.saveRecording(
                        id: recordingId, audioData: audioData, type: .voice, duration: duration
                    )
                    RecoveryStateManager.shared.clearState()
                }
                guard appState.recordingState == .processing else { return }
                await MainActor.run {
                    appState.errorMessage = "Cloud limit reached. Download a local model in Settings to continue."
                    appState.isEmptyTranscription = false
                    appState.deviceFallbackWarning = nil
                    appState.recordingState = .error
                    appState.recordingStartTime = nil
                    handleRecordingStateChange(.error)
                }
            }
        } catch {
            _ = await stopVoiceRealtimeSession(finalize: false)
            Log.app.error("stopRecording: ERROR - \(error.localizedDescription)")
            let isEmptyTranscription: Bool = {
                guard case .emptyTranscription = error as? TranscriptionError else { return false }
                return true
            }()

            if let audioData = capturedAudioData {
                let duration = recordingStartTime.map { stopTime.timeIntervalSince($0) } ?? 0
                RecordingsLibraryStorage.shared.saveRecording(
                    id: recordingId,
                    audioData: audioData,
                    type: .voice,
                    duration: duration
                )
                RecoveryStateManager.shared.clearState()
            }

            guard appState.recordingState == .processing else {
                Log.app.warning("stopRecording: state changed during processing (now \(self.appState.recordingState)), dropping error")
                return
            }
            await MainActor.run {
                appState.errorMessage = error.localizedDescription
                appState.isEmptyTranscription = isEmptyTranscription
                appState.deviceFallbackWarning = nil
                appState.recordingState = .error
                appState.recordingStartTime = nil
                handleRecordingStateChange(.error)
            }
        }

        Log.app.info("stopRecording: END")
    }

    // MARK: - Realtime Transcription (WebSocket)

    private func setupVoiceRealtimeTranscriptionIfNeeded() async {
        guard SettingsStorage.shared.transcriptionProvider == .cloud,
              SettingsStorage.shared.transcriptionRealtimeSocketEnabled
        else {
            audioRecorder.onRealtimeAudioData = nil
            voiceRealtimeSessionEnabled = false
            voiceRealtimeAccumulator = nil
            return
        }

        let accumulator = RealtimeVoiceAccumulator()
        voiceRealtimeAccumulator = accumulator

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
            Log.transcription.info("Dictation RT status: \(String(describing: status))")
        }

        rtService.onSegmentBoundary = { [weak accumulator] _ in
            guard let accumulator else { return }
            Task {
                await accumulator.markSegmentBoundary()
            }
        }

        rtService.onError = { error in
            Log.transcription.error("Dictation RT error: \(error.localizedDescription)")
        }

        do {
            let languageHints = SettingsStorage.shared.favoriteLanguages

            try await rtService.connect(
                languageHints: languageHints,
                strictLanguageHints: !languageHints.isEmpty,
                audioConfig: .defaultPCM16kMono,
            )

            voiceRealtimeSessionEnabled = true
            Log.transcription.info("Dictation RT connected")
        } catch {
            audioRecorder.onRealtimeAudioData = nil
            voiceRealtimeSessionEnabled = false
            voiceRealtimeAccumulator = nil
            Log.transcription.warning(
                "Dictation RT unavailable (\(error.localizedDescription)); fallback to async transcription will be used"
            )
        }
    }

    private func stopVoiceRealtimeSession(finalize: Bool) async -> (text: String, didReceiveFinalization: Bool) {
        audioRecorder.onRealtimeAudioData = nil

        let accumulator = voiceRealtimeAccumulator
        let wasEnabled = voiceRealtimeSessionEnabled
        var didReceiveFinalization = false

        defer {
            voiceRealtimeSessionEnabled = false
            voiceRealtimeAccumulator = nil
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

    // MARK: - Escape Cancel Handler

    private func setupEscapeCancelHandler() {
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
                      self.appState.recordingState == .recording else { return }
                NotchManager.shared.startRecording(mode: .voice)
            }
        }

        // On second shortcut press (confirmed cancel): cancel recording
        escapeService.onCancel = { [weak self] in
            Task { @MainActor in
                let shouldSaveAudio = SettingsStorage.shared.escapeCancelSaveAudio
                await self?.cancelRecording()
                let message = shouldSaveAudio ? "Recording cancelled and saved" : "Recording cancelled"
                NotchManager.shared.showInfo(message: message)
            }
        }

        escapeService.activate()
    }

    private func shouldUseRealtimeFallbackText(
        _ text: String,
        didReceiveFinalization: Bool,
        recordingDurationSeconds: TimeInterval
    ) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let wordCount = trimmed.split { $0.isWhitespace || $0.isNewline }.count
        let charCount = trimmed.count
        let hasSentenceEnding = trimmed.hasSuffix(".")
            || trimmed.hasSuffix("!")
            || trimmed.hasSuffix("?")
            || trimmed.contains("\n")

        if didReceiveFinalization {
            // Finalized realtime output can occasionally be a very short fragment (e.g. "But.").
            // For recordings longer than a short utterance, require a minimal text quality bar
            // and fall back to async full-audio transcription otherwise.
            if recordingDurationSeconds <= 1.2 {
                return true
            }
            if wordCount >= 2 {
                return true
            }
            if charCount >= 12 {
                return true
            }
            return false
        }

        // Fallback policy when finalize is delayed:
        // 1) sentence-like chunk with at least 4 words
        // 2) or sufficiently long chunk (>= 8 words)
        // 3) or raw length safety net (>= 48 chars)
        if hasSentenceEnding, wordCount >= 4 {
            return true
        }
        if wordCount >= 8 {
            return true
        }
        if charCount >= 48 {
            return true
        }

        return false
    }
}
