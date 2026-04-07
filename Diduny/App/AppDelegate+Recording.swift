import AppKit
import Combine
import Foundation

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
        let recordingState = appState.recordingState
        Log.app.info("toggleRecording called, current state: \(recordingState)")
        voicePipelineTask?.cancel()
        voicePipelineTask = Task {
            await self.performToggleRecording()
        }
    }

    func performToggleRecording() async {
        let recordingState = appState.recordingState
        Log.app.info("performToggleRecording: state = \(recordingState)")
        switch recordingState {
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
            Log.app.info("State is \(recordingState), ignoring toggle")
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
                let sourceDevice = audioRecorder.currentRecordingDeviceInfo
                let audioData = try await audioRecorder.stopRecording()
                let duration = recordingStartTime.map { stopTime.timeIntervalSince($0) } ?? 0
                RecordingsLibraryStorage.shared.saveRecording(
                    audioData: audioData,
                    type: .voice,
                    duration: duration,
                    sourceDevice: sourceDevice
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
        switch SettingsStorage.shared.effectiveTranscriptionProvider {
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

        // Resolve device (nil preference = System Default)
        if let preferredUID = appState.preferredDeviceUID,
           !audioDeviceManager.isDeviceAvailable(uid: preferredUID)
        {
            Log.app.warning("startRecording: Preferred device UID is unavailable: \(preferredUID)")
        }

        let (device, didFallback) = audioDeviceManager.resolveDevice(
            preferredUID: appState.preferredDeviceUID
        )
        if let device {
            Log.app.info(
                "startRecording: Device resolution result = \(device.name), transport=\(device.transportType.displayName), sampleRate=\(Int(device.sampleRate)), uid=\(device.uid)"
            )
        }
        if didFallback, let name = device?.name {
            Log.app.warning("startRecording: Preferred device unavailable, using \(name)")
            appState.deviceFallbackWarning = "Selected microphone unavailable. Using \(name)"
            if device?.isDefault == true {
                appState.preferredDeviceUID = nil
                Log.app.info("startRecording: Cleared stale preferred microphone UID and switched to System Default")
            }
        }
        guard device != nil else {
            Log.app.error("startRecording: No audio input devices available")
            appState.errorMessage = "No microphone found. Please connect a microphone."
            appState.recordingState = .error
            handleRecordingStateChange(.error)
            return
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
            // Set up realtime callback BEFORE starting recorder (AudioRecorderService
            // snapshots onRealtimeAudioData at start time). WebSocket connects in background.
            setupVoiceRealtimeTranscriptionIfNeeded()

            Log.app.info("startRecording: Starting audio recording")
            try await audioRecorder.startRecording(device: device)
            Log.app.info("startRecording: Recording started successfully")

            // Only set recording state AFTER audio engine is confirmed working
            let recordingStateAfterStart = appState.recordingState
            guard recordingStateAfterStart == .processing else {
                Log.app.warning("startRecording: state changed during init (now \(recordingStateAfterStart)), aborting")
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

            wireDeviceLostNotification()

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
        var originalWAVData: Data?
        let recordingId = UUID()
        let sourceDevice = audioRecorder.currentRecordingDeviceInfo

        do {
            Log.app.info("stopRecording: Stopping audio recorder")
            let audioData = try await audioRecorder.stopRecording()
            Log.app.info("stopRecording: Got audio data, size = \(audioData.count) bytes")

            // Preserve original WAV for potential Whisper fallback (Whisper can't parse FLAC)
            originalWAVData = audioData

            // Compress WAV → FLAC for smaller storage (skipped for < 1MB)
            let compressedData = await AudioCompressionService.compressToFLAC(audioData: audioData)
            capturedAudioData = compressedData

            let realtimeResult = await stopVoiceRealtimeSession(finalize: true)

            let text: String
            if !realtimeResult.text.isEmpty {
                text = realtimeResult.text
                Log.app.info("stopRecording: Using realtime transcription (\(text.count) chars)")
            } else if SettingsStorage.shared.effectiveTranscriptionProvider == .local {
                // Local Whisper — needs original WAV data
                text = try await whisperTranscriptionService.transcribe(audioData: audioData)
                Log.app.info("stopRecording: Local Whisper transcription (\(text.count) chars)")
            } else if let connectionError = voiceRealtimeConnectionError {
                throw TranscriptionError.cloudConnectionFailed(connectionError)
            } else {
                throw TranscriptionError.emptyTranscription
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

            let processingState = appState.recordingState
            guard processingState == .processing else {
                Log.app
                    .warning(
                        "stopRecording: state changed during processing (now \(processingState)), dropping result"
                    )
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

            // Save to recordings library (uses compressed data if available)
            let duration = recordingStartTime.map { stopTime.timeIntervalSince($0) } ?? 0
            RecordingsLibraryStorage.shared.saveRecording(
                id: recordingId,
                audioData: compressedData,
                type: .voice,
                duration: duration,
                transcriptionText: text,
                sourceDevice: sourceDevice
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

            // Try falling back to local Whisper model (use original WAV since Whisper can't parse FLAC)
            if let wavData = originalWAVData, WhisperModelManager.shared.selectedModel() != nil {
                NotchManager.shared.showInfo(message: "Cloud limit reached. Switching to local model.", duration: 2.0)
                do {
                    let text = try await whisperTranscriptionService.transcribe(audioData: wavData)
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
                    if let audioData = capturedAudioData {
                        RecordingsLibraryStorage.shared.saveRecording(
                            id: recordingId, audioData: audioData, type: .voice,
                            duration: duration, transcriptionText: text,
                            sourceDevice: sourceDevice
                        )
                    }
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
                        id: recordingId, audioData: audioData, type: .voice, duration: duration,
                        sourceDevice: sourceDevice
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
                    duration: duration,
                    sourceDevice: sourceDevice
                )
                RecoveryStateManager.shared.clearState()
            }

            let processingState = appState.recordingState
            guard processingState == .processing else {
                Log.app
                    .warning(
                        "stopRecording: state changed during processing (now \(processingState)), dropping error"
                    )
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

    private func setupVoiceRealtimeTranscriptionIfNeeded() {
        guard SettingsStorage.shared.effectiveTranscriptionProvider == .cloud else {
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

        voiceRealtimeConnectionError = nil

        // Connect WebSocket in background — don't block recording start
        Task {
            do {
                let languageHints = SettingsStorage.shared.favoriteLanguages

                try await rtService.connect(
                    languageHints: languageHints,
                    strictLanguageHints: !languageHints.isEmpty,
                    audioConfig: .defaultPCM16kMono
                )

                await MainActor.run {
                    self.voiceRealtimeSessionEnabled = true
                }
                Log.transcription.info("Dictation RT connected")
            } catch {
                await MainActor.run {
                    self.audioRecorder.onRealtimeAudioData = nil
                    self.voiceRealtimeSessionEnabled = false
                    self.voiceRealtimeAccumulator = nil
                    self.voiceRealtimeConnectionError = error.localizedDescription
                }
                Log.transcription.warning(
                    "Dictation RT connection failed: \(error.localizedDescription)"
                )
            }
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
                      appState.recordingState == .recording else { return }
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
}
