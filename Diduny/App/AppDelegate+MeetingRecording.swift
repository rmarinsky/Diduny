import AppKit
import Foundation

// MARK: - Meeting Recording

extension AppDelegate {
    @objc func toggleMeetingRecording() {
        let meetingRecordingState = appState.meetingRecordingState
        Log.app.info("toggleMeetingRecording called, current state: \(meetingRecordingState)")
        meetingPipelineTask?.cancel()
        meetingPipelineTask = Task {
            await self.performToggleMeetingRecording()
        }
    }

    func performToggleMeetingRecording() async {
        let meetingRecordingState = appState.meetingRecordingState
        switch meetingRecordingState {
        case .idle:
            await startMeetingRecording()
        case .recording:
            await stopMeetingRecording()
        case .processing:
            Log.app.info("Meeting state is processing, canceling...")
            await cancelMeetingRecording()
        default:
            Log.app.info("Meeting state is \(meetingRecordingState), ignoring toggle")
        }
    }

    func cancelMeetingRecording() async {
        Log.app.info("cancelMeetingRecording: BEGIN")

        // Cancel any in-flight pipeline task
        meetingPipelineTask?.cancel()
        meetingPipelineTask = nil

        let recordingStartTime = appState.meetingRecordingStartTime
        let stopTime = Date()

        // Deactivate chapter bookmark hotkey
        hotkeyService.unregisterChapterHotkey()

        // Deactivate escape cancel handler
        EscapeCancelService.shared.deactivate()

        // Disconnect real-time transcription (if active)
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
                    Log.app.info("cancelMeetingRecording: audio saved after cancel")
                } else {
                    await meetingRecorderService.cancelRecording()
                }
            } catch {
                Log.app
                    .warning("cancelMeetingRecording: failed to save audio on cancel - \(error.localizedDescription)")
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

        guard canStartRecording(kind: .meeting) else {
            Log.app.info("startMeetingRecording: blocked by another active recording mode")
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

        let cloudModeEnabled = SettingsStorage.shared.effectiveMeetingRealtimeTranscriptionEnabled

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
            meetingRecorderService.onRealtimeAudioData = nil

            if meetingRecorderService.audioSource == .systemPlusMicrophone {
                let (device, didFallback) = audioDeviceManager.resolveDevice(
                    preferredUID: appState.preferredDeviceUID
                )
                appState.deviceFallbackWarning = nil
                if let device {
                    Log.app.info(
                        "startMeetingRecording: Device resolution result = \(device.name), transport=\(device.transportType.displayName), sampleRate=\(Int(device.sampleRate)), uid=\(device.uid)"
                    )
                }
                if didFallback, let name = device?.name {
                    Log.app.warning("startMeetingRecording: Preferred device unavailable, using \(name)")
                    appState.deviceFallbackWarning = "Selected microphone unavailable. Using \(name)"
                    if device?.isDefault == true {
                        appState.preferredDeviceUID = nil
                        Log.app
                            .info(
                                "startMeetingRecording: Cleared stale preferred microphone UID and switched to System Default"
                            )
                    }
                }
                meetingRecorderService.microphoneDevice = device
            } else {
                meetingRecorderService.microphoneDevice = nil
                appState.deviceFallbackWarning = nil
            }

            try await meetingRecorderService.startRecording()
            Log.app.info("Meeting recording started")

            // Setup real-time transcription in Cloud mode
            var store: LiveTranscriptStore?
            if cloudModeEnabled {
                store = await setupRealtimeTranscription()
            } else {
                Log.app.info("Local mode selected — recording audio only")
            }

            // Only set recording state AFTER confirmed working
            let recordingStateAfterStart = appState.meetingRecordingState
            guard recordingStateAfterStart == .processing else {
                Log.app
                    .warning(
                        "startMeetingRecording: state changed during init (now \(recordingStateAfterStart)), aborting"
                    )
                await meetingRecorderService.cancelRecording()
                if let token = meetingActivityToken {
                    ProcessInfo.processInfo.endActivity(token)
                    meetingActivityToken = nil
                }
                return
            }
            await MainActor.run {
                appState.meetingRecordingState = .recording
                appState.meetingRecordingStartTime = Date()
                appState.liveTranscriptStore = store
                handleMeetingStateChange(.recording)
            }

            // Show transcript window only if we have real-time transcription
            if let store {
                await MainActor.run {
                    TranscriptionWindowController.shared.showWindow(store: store)
                }
            }

            // Activate escape cancel handler
            await MainActor.run {
                setupMeetingEscapeCancelHandler()
            }

            // Activate chapter bookmark hotkey
            await MainActor.run {
                appState.meetingChapters = []
                hotkeyService.registerChapterHotkey { [weak self] in
                    self?.addMeetingChapter()
                }
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

            // End App Nap prevention on failed start
            if let token = meetingActivityToken {
                ProcessInfo.processInfo.endActivity(token)
                meetingActivityToken = nil
            }

            await MainActor.run {
                appState.errorMessage = error.localizedDescription
                appState.meetingRecordingState = .error
                handleMeetingStateChange(.error)
            }
        }
    }

    // MARK: - Real-Time Transcription Setup

    private func setupRealtimeTranscription() async -> LiveTranscriptStore {
        let store = await MainActor.run { LiveTranscriptStore() }

        let rtService = realtimeTranscriptionService

        // Stream the exact same mixed mono audio that is written to fallback WAV.
        meetingRecorderService.onRealtimeAudioData = { [weak rtService] pcmData in
            rtService?.sendAudioData(pcmData)
        }

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

        rtService.onSegmentBoundary = { [weak store] _ in
            Task { @MainActor in
                store?.markSegmentBoundary()
            }
        }

        rtService.onError = { error in
            Log.transcription.error("Realtime transcription error: \(error.localizedDescription)")
            // Don't stop recording — file recording continues independently
        }

        // Connect WebSocket (non-blocking — recording works even if this fails)
        do {
            let languageHints = SettingsStorage.shared.favoriteLanguages

            try await rtService.connect(
                languageHints: languageHints,
                strictLanguageHints: !languageHints.isEmpty
            )
            await MainActor.run {
                store.isActive = true
            }
            Log.transcription.info("Meeting real-time transcription connected successfully")
        } catch {
            Log.transcription.error("Meeting real-time transcription FAILED to connect: \(error.localizedDescription)")
            await MainActor.run {
                store.isActive = true
                store.connectionStatus = .failed(error.localizedDescription)
            }
            // Recording continues — fallback to async transcription on stop
        }

        return store
    }

    // MARK: - Stop Meeting Recording

    func addMeetingChapter() {
        guard appState.meetingRecordingState == .recording,
              let startTime = appState.meetingRecordingStartTime else { return }
        let elapsed = Date().timeIntervalSince(startTime)
        let chapterNumber = appState.meetingChapters.count + 1
        let chapter = MeetingChapter(timestampSeconds: elapsed, label: "Chapter \(chapterNumber)")
        appState.meetingChapters.append(chapter)
        NotchManager.shared.showInfo(message: "Chapter \(chapterNumber) added", duration: 1.0)
        Log.app.info("Meeting chapter \(chapterNumber) added at \(elapsed)s")
    }

    func stopMeetingRecording() async {
        Log.app.info("stopMeetingRecording: BEGIN")

        // Deactivate chapter bookmark hotkey
        hotkeyService.unregisterChapterHotkey()

        // Deactivate escape cancel handler
        EscapeCancelService.shared.deactivate()

        // Capture recording start time for duration calculation
        let recordingStartTime = appState.meetingRecordingStartTime

        await MainActor.run {
            appState.meetingRecordingState = .processing
            handleMeetingStateChange(.processing)
        }

        // Finalize and disconnect real-time transcription (if active)
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

        // Ensure App Nap prevention is always cleaned up
        defer {
            if let token = meetingActivityToken {
                ProcessInfo.processInfo.endActivity(token)
                meetingActivityToken = nil
            }
        }

        // Track URLs for library save and cleanup in error/cancel paths
        var capturedAudioURL: URL?
        var originalWavURL: URL?
        let stopTime = Date()
        let recordingId = UUID()

        func cleanupTemporaryAudio() {
            if let wavURL = originalWavURL {
                try? FileManager.default.removeItem(at: wavURL)
            }
            if let audioURL = capturedAudioURL {
                try? FileManager.default.removeItem(at: audioURL)
            }
        }

        do {
            guard let audioURL = try await meetingRecorderService.stopRecording() else {
                throw MeetingRecorderError.recordingFailed
            }
            capturedAudioURL = audioURL

            Log.app.info("Meeting recording stopped")

            // Compress WAV → FLAC before loading into memory (saves RAM and upload time)
            let compressedURL = await AudioCompressionService.compressToFLAC(wavURL: audioURL)
            let didCompress = compressedURL != audioURL
            if didCompress {
                originalWavURL = audioURL
                capturedAudioURL = compressedURL
            }

            let realtimeText = await MainActor.run { store?.finalTranscriptText ?? "" }
            let cloudModeEnabled = SettingsStorage.shared.effectiveMeetingRealtimeTranscriptionEnabled

            let text: String?
            if !realtimeText.isEmpty {
                text = realtimeText
                Log.app.info("Using real-time transcript (\(realtimeText.count) chars)")
            } else if cloudModeEnabled {
                Log.app.info("No real-time transcript, falling back to async API...")
                let audioData = try await loadAudioData(from: compressedURL)
                Log.app.info("Meeting recording size = \(audioData.count) bytes")

                text = try await transcriptionService.transcribeMeeting(audioData: audioData)
                Log.app.info("Async meeting transcription received (\(text?.count ?? 0) chars)")
            } else {
                text = nil
                Log.app.info("Saving meeting recording without automatic transcription")
            }

            let processingState = appState.meetingRecordingState
            guard processingState == .processing else {
                Log.app
                    .warning(
                        "stopMeetingRecording: state changed during processing (now \(processingState)), dropping result"
                    )
                cleanupTemporaryAudio()
                RecoveryStateManager.shared.clearState()
                return
            }

            if let text {
                clipboardService.copy(text: text, behavior: .raw)
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

                await MainActor.run {
                    appState.lastTranscription = text
                    appState.meetingRecordingState = .success
                    appState.meetingRecordingStartTime = nil
                    handleMeetingStateChange(.success)
                }
            } else {
                await MainActor.run {
                    appState.lastTranscription = nil
                    appState.meetingRecordingState = .success
                    appState.meetingRecordingStartTime = nil
                    handleMeetingStateChange(.success)
                }

                if !cloudModeEnabled {
                    NotchManager.shared.showInfo(
                        message: "Recording saved. Open Recordings and choose a local model to transcribe.",
                        duration: 3.0
                    )
                }
            }
            Log.app.info("stopMeetingRecording: SUCCESS")

            let duration = recordingStartTime.map { stopTime.timeIntervalSince($0) } ?? 0
            RecordingsLibraryStorage.shared.saveRecording(
                id: recordingId,
                audioURL: compressedURL,
                type: .meeting,
                duration: duration,
                transcriptionText: text
            )

            if SettingsStorage.shared.playSoundOnCompletion {
                NSSound(named: .init("Funk"))?.play()
            }

            RecoveryStateManager.shared.clearState()
            if didCompress {
                try? FileManager.default.removeItem(at: audioURL)
            }
            try? FileManager.default.removeItem(at: compressedURL)

        } catch is CancellationError {
            Log.app.info("stopMeetingRecording: Cancelled")
            cleanupTemporaryAudio()
            RecoveryStateManager.shared.clearState()
            await MainActor.run {
                appState.meetingRecordingState = .idle
                appState.meetingRecordingStartTime = nil
                handleMeetingStateChange(.idle)
            }
            return
        } catch {
            Log.app.error("Meeting transcription failed: \(error)")

            if let audioURL = capturedAudioURL {
                let duration = recordingStartTime.map { stopTime.timeIntervalSince($0) } ?? 0
                RecordingsLibraryStorage.shared.saveRecording(
                    id: recordingId,
                    audioURL: audioURL,
                    type: .meeting,
                    duration: duration
                )
                cleanupTemporaryAudio()
                RecoveryStateManager.shared.clearState()
            }

            let processingState = appState.meetingRecordingState
            guard processingState == .processing else {
                Log.app
                    .warning(
                        "stopMeetingRecording: state changed during processing (now \(processingState)), dropping error"
                    )
                return
            }

            let userMessage: String = if let transcriptionError = error as? TranscriptionError {
                transcriptionError.localizedDescription
            } else {
                "Transcription failed: \(error.localizedDescription). Audio saved to Recordings."
            }

            await MainActor.run {
                appState.errorMessage = userMessage
                appState.meetingRecordingState = .error
                appState.meetingRecordingStartTime = nil
                handleMeetingStateChange(.error)
            }
        }

        Log.app.info("stopMeetingRecording: END")
    }

    // MARK: - Escape Cancel Handler

    private func setupMeetingEscapeCancelHandler() {
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
                      appState.meetingRecordingState == .recording else { return }
                NotchManager.shared.startRecording(mode: .meeting)
            }
        }

        // On second shortcut press (confirmed cancel): cancel recording
        escapeService.onCancel = { [weak self] in
            Task { @MainActor in
                let shouldSaveAudio = SettingsStorage.shared.escapeCancelSaveAudio
                await self?.cancelMeetingRecording()
                let message = shouldSaveAudio ? "Recording cancelled and saved" : "Recording cancelled"
                NotchManager.shared.showInfo(message: message)
            }
        }

        escapeService.activate()
    }
}
