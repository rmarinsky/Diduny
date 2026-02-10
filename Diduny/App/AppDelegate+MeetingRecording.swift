import AppKit
import AVFoundation
import Foundation

// MARK: - Meeting Recording

extension AppDelegate {
    @objc func toggleMeetingRecording() {
        Log.app.info("toggleMeetingRecording called, current state: \(self.appState.meetingRecordingState)")
        Task {
            await self.performToggleMeetingRecording()
        }
    }

    func performToggleMeetingRecording() async {
        switch appState.meetingRecordingState {
        case .idle:
            await startMeetingRecording()
        case .recording:
            await stopMeetingRecording()
        case .processing:
            Log.app.info("Meeting state is processing, canceling...")
            await cancelMeetingRecording()
        default:
            Log.app.info("Meeting state is \(self.appState.meetingRecordingState), ignoring toggle")
        }
    }

    @available(macOS 13.0, *)
    func cancelMeetingRecording() async {
        Log.app.info("cancelMeetingRecording: BEGIN")

        // Deactivate escape cancel handler
        EscapeCancelService.shared.deactivate()

        // Disconnect real-time transcription and stop mic capture
        await realtimeTranscriptionService.disconnect()
        stopMicrophoneCapture()

        // Cancel meeting recorder
        meetingRecorderService.cancelRecording()

        // Mark transcript as inactive but keep window open for review
        await MainActor.run {
            appState.liveTranscriptStore?.isActive = false
            appState.liveTranscriptStore = nil
        }

        // End App Nap prevention
        if let token = meetingActivityToken {
            ProcessInfo.processInfo.endActivity(token)
            meetingActivityToken = nil
        }

        // Clear recovery state
        RecoveryStateManager.shared.clearState()

        // Reset state to idle
        await MainActor.run {
            appState.meetingRecordingState = .idle
            appState.meetingRecordingStartTime = nil
            handleMeetingStateChange(.idle)
        }

        Log.app.info("cancelMeetingRecording: END")
    }

    func startMeetingRecording() async {
        Log.app.info("startMeetingRecording: BEGIN")

        guard #available(macOS 13.0, *) else {
            Log.app.warning("Meeting recording requires macOS 13.0+")
            await MainActor.run {
                appState.errorMessage = "Meeting recording requires macOS 13.0 or later"
                appState.meetingRecordingState = .error
                handleMeetingStateChange(.error)
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
                appState.meetingRecordingState = .error
                handleMeetingStateChange(.error)
            }
            return
        }

        guard let apiKey = KeychainManager.shared.getSonioxAPIKey(), !apiKey.isEmpty else {
            Log.app.warning("No API key for meeting recording")
            await MainActor.run {
                appState.errorMessage = "Please add your Soniox API key in Settings"
                appState.meetingRecordingState = .error
                handleMeetingStateChange(.error)
            }
            return
        }

        // Prevent App Nap during meeting recording
        meetingActivityToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "Meeting recording in progress"
        )

        // Show processing state while initializing (before we confirm it works)
        await MainActor.run {
            appState.meetingRecordingState = .processing
            handleMeetingStateChange(.processing)
        }

        do {
            meetingRecorderService.audioSource = SettingsStorage.shared.meetingAudioSource

            // Set microphone device for mixed recording
            if let deviceID = appState.selectedDeviceID {
                meetingRecorderService.microphoneDevice = audioDeviceManager.device(for: deviceID)
            } else {
                meetingRecorderService.microphoneDevice = audioDeviceManager.getCurrentDefaultDevice()
            }

            try await meetingRecorderService.startRecording()
            Log.app.info("Meeting recording started")

            // Setup real-time transcription
            let store = await setupRealtimeTranscription(apiKey: apiKey)

            // Only set recording state AFTER confirmed working
            await MainActor.run {
                appState.meetingRecordingState = .recording
                appState.meetingRecordingStartTime = Date()
                appState.liveTranscriptStore = store
                handleMeetingStateChange(.recording)
            }

            // Show transcript window
            await MainActor.run {
                TranscriptionWindowController.shared.showWindow(store: store)
            }

            // Activate escape cancel handler
            await MainActor.run {
                setupMeetingEscapeCancelHandler()
            }

            // Save recovery state in case of crash
            if let path = meetingRecorderService.currentRecordingPath {
                let state = RecoveryState(
                    tempFilePath: path,
                    startTime: Date(),
                    recordingType: .meeting
                )
                RecoveryStateManager.shared.saveState(state)
            }
        } catch {
            Log.app.error("Meeting recording failed: \(error)")
            await MainActor.run {
                appState.errorMessage = error.localizedDescription
                appState.meetingRecordingState = .error
                handleMeetingStateChange(.error)
            }
        }
    }

    // MARK: - Real-Time Transcription Setup

    @available(macOS 13.0, *)
    private func setupRealtimeTranscription(apiKey: String) async -> LiveTranscriptStore {
        let store = await MainActor.run { LiveTranscriptStore() }

        let rtService = realtimeTranscriptionService

        // Clear mic buffer
        micBufferLock.withLock {
            micAudioBuffer = Data()
        }

        // Wire raw PCM audio from system capture to WebSocket,
        // mixing in microphone audio before sending
        let captureService = meetingRecorderService.systemAudioCaptureService
        NSLog("[MeetingRT] systemAudioCaptureService is %@", captureService == nil ? "nil" : "present")
        captureService?.onRawAudioData = { [weak self, weak rtService] systemData in
            guard let self, let rtService else { return }

            let sampleCount = systemData.count / MemoryLayout<Int16>.size

            // Grab matching amount of mic audio from buffer
            self.micBufferLock.lock()
            let micChunkSize = min(self.micAudioBuffer.count, systemData.count)
            let micData = micChunkSize > 0 ? Data(self.micAudioBuffer.prefix(micChunkSize)) : Data()
            if micChunkSize > 0 {
                self.micAudioBuffer.removeFirst(micChunkSize)
            }
            self.micBufferLock.unlock()

            // Interleave into stereo: left = system audio, right = mic audio
            var stereoData = Data(count: sampleCount * 2 * MemoryLayout<Int16>.size)
            stereoData.withUnsafeMutableBytes { stereoRaw in
                let stereo = stereoRaw.bindMemory(to: Int16.self)
                systemData.withUnsafeBytes { sysRaw in
                    let sys = sysRaw.bindMemory(to: Int16.self)
                    micData.withUnsafeBytes { micRaw in
                        let mic = micRaw.bindMemory(to: Int16.self)
                        for i in 0 ..< sampleCount {
                            stereo[i * 2] = sys[i]                        // Left = system
                            stereo[i * 2 + 1] = i < mic.count ? mic[i] : 0 // Right = mic
                        }
                    }
                }
            }
            rtService.sendAudioData(stereoData)
        }

        // Start microphone capture (buffers audio for mixing above)
        setupMicrophoneCapture()

        // Wire token callbacks
        rtService.onTokensReceived = { [weak store] tokens in
            Task { @MainActor in
                store?.processTokens(tokens)
            }
        }

        rtService.onConnectionStatusChanged = { [weak store] status in
            Task { @MainActor in
                store?.connectionStatus = status
            }
        }

        rtService.onError = { error in
            Log.transcription.error("Realtime transcription error: \(error.localizedDescription)")
            // Don't stop recording — file recording continues independently
        }

        // Connect WebSocket (non-blocking — recording works even if this fails)
        do {
            try await rtService.connect(apiKey: apiKey)
            await MainActor.run {
                store.isActive = true
            }
            NSLog("[MeetingRT] Real-time transcription connected successfully")
        } catch {
            NSLog("[MeetingRT] Real-time transcription FAILED to connect: %@", error.localizedDescription)
            await MainActor.run {
                store.isActive = true
                store.connectionStatus = .failed(error.localizedDescription)
            }
            // Recording continues — fallback to async transcription on stop
        }

        return store
    }

    // MARK: - Stop Meeting Recording

    func stopMeetingRecording() async {
        Log.app.info("stopMeetingRecording: BEGIN")

        guard #available(macOS 13.0, *) else { return }

        // Deactivate escape cancel handler
        EscapeCancelService.shared.deactivate()

        // Capture recording start time for duration calculation
        let recordingStartTime = appState.meetingRecordingStartTime

        await MainActor.run {
            appState.meetingRecordingState = .processing
            handleMeetingStateChange(.processing)
        }

        // Finalize and disconnect real-time transcription, stop mic capture
        stopMicrophoneCapture()
        await realtimeTranscriptionService.finalize()
        await realtimeTranscriptionService.disconnect()

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

            Log.app.info("Meeting recording stopped")

            // Check if we have real-time transcript
            let realtimeText = await MainActor.run { store?.finalTranscriptText ?? "" }

            let text: String
            if !realtimeText.isEmpty {
                // Use real-time transcript
                text = realtimeText
                Log.app.info("Using real-time transcript (\(realtimeText.count) chars)")
            } else {
                // Fallback: upload WAV to async REST API
                Log.app.info("No real-time transcript, falling back to async API...")
                let audioData = try Data(contentsOf: audioURL)
                Log.app.info("Meeting recording size = \(audioData.count) bytes")

                guard let apiKey = KeychainManager.shared.getSonioxAPIKey() else {
                    throw TranscriptionError.noAPIKey
                }

                transcriptionService.apiKey = apiKey
                text = try await transcriptionService.transcribeMeeting(audioData: audioData)
                Log.app.info("Async meeting transcription received: \(text.prefix(100))...")
            }

            clipboardService.copy(text: text)
            Log.app.info("stopMeetingRecording: Text copied to clipboard")

            if SettingsStorage.shared.autoPaste {
                Log.app.info("stopMeetingRecording: Auto-pasting")
                do {
                    try await clipboardService.paste()
                } catch ClipboardError.accessibilityNotGranted {
                    Log.app.warning("stopMeetingRecording: Accessibility permission needed")
                    PermissionManager.shared.showPermissionAlert(for: .accessibility)
                } catch {
                    Log.app.error("stopMeetingRecording: Paste failed - \(error.localizedDescription)")
                }
            }

            // Update state to success
            await MainActor.run {
                appState.lastTranscription = text
                appState.meetingRecordingState = .success
                appState.meetingRecordingStartTime = nil
                handleMeetingStateChange(.success)
            }
            Log.app.info("stopMeetingRecording: SUCCESS")

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
            Log.app.error("Meeting transcription failed: \(error)")

            // Save recording without transcription so user can process later
            if let audioURL = capturedAudioURL {
                let duration = recordingStartTime.map { stopTime.timeIntervalSince($0) } ?? 0
                RecordingsLibraryStorage.shared.saveRecording(
                    audioURL: audioURL,
                    type: .meeting,
                    duration: duration
                )
                // Clean up temp file after library save
                try? FileManager.default.removeItem(at: audioURL)
            }

            await MainActor.run {
                appState.errorMessage = error.localizedDescription
                appState.meetingRecordingState = .error
                appState.meetingRecordingStartTime = nil
                handleMeetingStateChange(.error)
            }
        }

        // End App Nap prevention
        if let token = meetingActivityToken {
            ProcessInfo.processInfo.endActivity(token)
            meetingActivityToken = nil
        }

        // Keep transcript window open — user closes manually

        Log.app.info("stopMeetingRecording: END")
    }

    // MARK: - Escape Cancel Handler

    private func setupMeetingEscapeCancelHandler() {
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
                      self.appState.meetingRecordingState == .recording else { return }
                NotchManager.shared.startRecording(mode: .meeting)
            }
        }

        // On second escape (confirmed cancel): cancel recording
        escapeService.onCancel = { [weak self] in
            guard #available(macOS 13.0, *) else { return }
            Task { @MainActor in
                await self?.cancelMeetingRecording()
                NotchManager.shared.showInfo(message: "Recording cancelled")
            }
        }

        escapeService.activate()
    }

    // MARK: - Microphone Capture for Real-Time Transcription

    private func setupMicrophoneCapture() {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode

        // Set the microphone device if user has selected one
        if let deviceID = appState.selectedDeviceID,
           let device = audioDeviceManager.device(for: deviceID)
        {
            var audioDeviceID = device.id
            let propertySize = UInt32(MemoryLayout<AudioDeviceID>.size)
            let status = AudioUnitSetProperty(
                inputNode.audioUnit!,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &audioDeviceID,
                propertySize
            )
            if status != noErr {
                NSLog("[MeetingRT] Failed to set mic device: %d", status)
            }
        }

        let inputFormat = inputNode.outputFormat(forBus: 0)
        let inputSampleRate = inputFormat.sampleRate
        let targetSampleRate = 16000.0
        let ratio = inputSampleRate / targetSampleRate
        NSLog("[MeetingRT] Mic: %.0fHz %dch, downsample ratio=%.2f", inputSampleRate, inputFormat.channelCount, ratio)

        // Install tap — downsample + convert to int16 manually, buffer for mixing
        let bufferSize: AVAudioFrameCount = 4096
        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: inputFormat) { [weak self] buffer, _ in
            guard let self, let floatData = buffer.floatChannelData else { return }

            let inputFrames = Int(buffer.frameLength)
            let outputFrames = Int(Double(inputFrames) / ratio)
            guard outputFrames > 0 else { return }

            // Downsample and convert float32 → int16
            var int16Data = Data(count: outputFrames * MemoryLayout<Int16>.size)
            int16Data.withUnsafeMutableBytes { rawBuffer in
                let samples = rawBuffer.bindMemory(to: Int16.self)
                let channel = floatData[0]
                for i in 0 ..< outputFrames {
                    let srcIndex = min(Int(Double(i) * ratio), inputFrames - 1)
                    let clamped = max(-1.0, min(1.0, channel[srcIndex]))
                    samples[i] = Int16(clamped * Float(Int16.max))
                }
            }

            self.micBufferLock.lock()
            self.micAudioBuffer.append(int16Data)
            // Cap at 1 second of audio (32000 bytes at 16kHz int16)
            if self.micAudioBuffer.count > 32000 {
                self.micAudioBuffer.removeFirst(self.micAudioBuffer.count - 32000)
            }
            self.micBufferLock.unlock()
        }

        do {
            try engine.start()
            self.micEngine = engine
            NSLog("[MeetingRT] Microphone capture started (buffering for mix)")
        } catch {
            NSLog("[MeetingRT] Failed to start mic engine: %@", error.localizedDescription)
        }
    }

    private func stopMicrophoneCapture() {
        if let engine = micEngine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            micEngine = nil
            NSLog("[MeetingRT] Microphone capture stopped")
        }
    }
}
