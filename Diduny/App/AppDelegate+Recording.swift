import AppKit
import Combine
import Foundation

// MARK: - Recording Actions

extension AppDelegate {
    @objc func toggleRecording() {
        Log.app.info("toggleRecording called, current state: \(self.appState.recordingState)")
        Task {
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
            await cancelRecording()
        default:
            Log.app.info("State is \(self.appState.recordingState), ignoring toggle")
        }
    }

    func cancelRecording() async {
        Log.app.info("cancelRecording: BEGIN")

        // Stop audio level piping
        audioLevelCancellable?.cancel()
        audioLevelCancellable = nil

        // Deactivate escape cancel handler
        EscapeCancelService.shared.deactivate()

        // Cancel audio recorder
        audioRecorder.cancelRecording()

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
        case .soniox:
            guard let apiKey = KeychainManager.shared.getSonioxAPIKey(), !apiKey.isEmpty else {
                Log.app.warning("startRecording: No API key found")
                await MainActor.run {
                    appState.errorMessage = "Please add your Soniox API key in Settings"
                    appState.recordingState = .error
                    handleRecordingStateChange(.error)
                }
                return
            }
            Log.app.info("startRecording: Soniox API key found")
        case .whisperLocal:
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

        // Determine device with fallback to system default
        var device: AudioDevice?

        if let deviceID = appState.selectedDeviceID {
            // Validate selected device is still available using hardware-level check
            let (validDevice, didFallback) = audioDeviceManager.getValidDevice(selectedID: deviceID)
            device = validDevice

            if didFallback {
                // Device changed - notify user
                Log.app.warning("startRecording: Selected device (ID: \(deviceID)) unavailable, using \(device?.name ?? "default")")

                // Show warning notification to user
                if let fallbackName = device?.name {
                    await MainActor.run {
                        appState.deviceFallbackWarning = "Using \(fallbackName)"
                    }
                }
            } else {
                Log.app.info("startRecording: Using selected device: \(device?.name ?? "none")")
            }
        } else {
            // No device selected - use system default
            Log.app.info("startRecording: No device selected, using system default")
            device = audioDeviceManager.getCurrentDefaultDevice()
        }

        // If still no device available, try last resort or show error
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
            // Last resort: pick first available device
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
            Log.app.info("startRecording: Starting audio recording")
            try await audioRecorder.startRecording(device: device)
            Log.app.info("startRecording: Recording started successfully")

            // Only set recording state AFTER audio engine is confirmed working
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

        // Capture audio data first so it's available in both success and error paths
        var capturedAudioData: Data?

        do {
            Log.app.info("stopRecording: Stopping audio recorder")
            let audioData = try await audioRecorder.stopRecording()
            capturedAudioData = audioData
            Log.app.info("stopRecording: Got audio data, size = \(audioData.count) bytes")

            var service = activeTranscriptionService
            if SettingsStorage.shared.transcriptionProvider == .soniox {
                guard let apiKey = KeychainManager.shared.getSonioxAPIKey() else {
                    Log.app.error("stopRecording: No API key!")
                    throw TranscriptionError.noAPIKey
                }
                service.apiKey = apiKey
            }

            Log.app.info("stopRecording: Calling transcription service (\(SettingsStorage.shared.transcriptionProvider.rawValue))")
            let text = try await service.transcribe(audioData: audioData)
            Log.app.info("stopRecording: Transcription received: \(text.prefix(50))...")

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

            // Update state to success IMMEDIATELY after text is available
            // This ensures the UI shows checkmark right when user can work with the text
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
                audioData: audioData,
                type: .voice,
                duration: duration,
                transcriptionText: text
            )

            // Optional operations run after state change (non-blocking for UI)
            if SettingsStorage.shared.playSoundOnCompletion {
                Log.app.info("stopRecording: Playing sound")
                NSSound(named: .init("Funk"))?.play()
            }

            // Clear recovery state on success
            RecoveryStateManager.shared.clearState()

        } catch {
            Log.app.error("stopRecording: ERROR - \(error.localizedDescription)")
            let isEmptyTranscription: Bool = {
                guard case .emptyTranscription = error as? TranscriptionError else { return false }
                return true
            }()

            // Save recording without transcription so user can process later
            if let audioData = capturedAudioData {
                let duration = recordingStartTime.map { stopTime.timeIntervalSince($0) } ?? 0
                RecordingsLibraryStorage.shared.saveRecording(
                    audioData: audioData,
                    type: .voice,
                    duration: duration
                )
                RecoveryStateManager.shared.clearState()
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

        // End App Nap prevention
        if let token = recordingActivityToken {
            ProcessInfo.processInfo.endActivity(token)
            recordingActivityToken = nil
        }

        Log.app.info("stopRecording: END")
    }

    // MARK: - Escape Cancel Handler

    private func setupEscapeCancelHandler() {
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
                      self.appState.recordingState == .recording else { return }
                NotchManager.shared.startRecording(mode: .voice)
            }
        }

        // On second escape (confirmed cancel): cancel recording
        escapeService.onCancel = { [weak self] in
            Task { @MainActor in
                await self?.cancelRecording()
                NotchManager.shared.showInfo(message: "Recording cancelled")
            }
        }

        escapeService.activate()
    }
}
