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
        let targetLanguage = activeMeetingTranslationTargetLanguage
            ?? activeMeetingTranslationLanguagePair?.languageB
            ?? SettingsStorage.shared.voiceTranslationTargetLanguage

        // Deactivate escape cancel handler
        EscapeCancelService.shared.deactivate()

        // Disconnect real-time translation (if active)
        if appState.liveTranscriptStore != nil {
            await realtimeTranscriptionService.disconnect()
            meetingRecorderService.onRealtimeAudioData = nil
        }

        // Capture in-progress recording ID before stopRecording() clears it (RLR-M1).
        let cancelInProgressRecordingId = meetingRecorderService.currentRecordingId

        if SettingsStorage.shared.escapeCancelSaveAudio, meetingRecorderService.isRecording {
            do {
                if let audioURL = try await meetingRecorderService.stopRecording() {
                    let duration = recordingStartTime.map { stopTime.timeIntervalSince($0) } ?? 0
                    var saved = false
                    if let ipId = cancelInProgressRecordingId,
                       RecordingsLibraryStorage.shared.recordings.contains(where: { $0.id == ipId })
                    {
                        saved = RecordingsLibraryStorage.shared.finalizeInProgressRecording(
                            id: ipId,
                            audioURL: audioURL,
                            duration: duration,
                            endedAt: stopTime,
                            status: .unprocessed,
                            forceSave: true
                        )
                    } else {
                        saved = RecordingsLibraryStorage.shared.saveRecording(
                            id: cancelInProgressRecordingId,
                            audioURL: audioURL,
                            type: .meetingTranslation,
                            duration: duration,
                            translationTargetLanguageCode: targetLanguage,
                            createdAt: recordingStartTime ?? stopTime,
                            forceSave: true
                        ) != nil
                    }
                    if saved, let ipId = cancelInProgressRecordingId {
                        if let store = try? InProgressRecordingStore.sharedStore() {
                            try? await store.cleanup(recordingId: ipId)
                        }
                        try? FileManager.default.removeItem(at: audioURL)
                        Log.app.info("cancelMeetingTranslationRecording: audio saved after cancel")
                    } else if !saved, let ipId = cancelInProgressRecordingId {
                        _ = RecordingsLibraryStorage.shared.markNeedsRecovery(
                            id: ipId,
                            endedAt: stopTime,
                            durationSeconds: duration
                        )
                    }
                } else {
                    await meetingRecorderService.cancelRecording()
                    if let ipId = cancelInProgressRecordingId {
                        await discardLiveMeetingRow(id: ipId)
                    }
                }
            } catch {
                Log.app
                    .warning(
                        "cancelMeetingTranslationRecording: failed to save audio on cancel - \(error.localizedDescription)"
                    )
                await meetingRecorderService.cancelRecording()
                if let ipId = cancelInProgressRecordingId {
                    _ = RecordingsLibraryStorage.shared.markNeedsRecovery(id: ipId, endedAt: stopTime)
                }
            }
        } else {
            // Cancel meeting recorder without persisting
            await meetingRecorderService.cancelRecording()
            if let ipId = cancelInProgressRecordingId {
                await discardLiveMeetingRow(id: ipId)
            }
        }

        // Release the live transcript after the Flow panel returns to idle.
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
            activeMeetingTranslationLanguagePair = nil
            activeMeetingTranslationTargetLanguage = nil
        }

        Log.app.info("cancelMeetingTranslationRecording: END")
    }

    func startMeetingTranslationRecording(languagePair requestedPair: TranslationLanguagePair? = nil) async {
        Log.app.info("startMeetingTranslationRecording: BEGIN")

        guard canStartRecording(kind: .meetingTranslation) else {
            Log.app.info("startMeetingTranslationRecording: blocked by another active recording mode")
            return
        }

        // Request screen capture permission on-demand
        let hasPermission = await PermissionManager.shared.ensureScreenRecordingPermission(context: .meetingTranslation)
        appState.screenCapturePermissionGranted = hasPermission

        guard hasPermission else {
            Log.app.warning("Screen capture permission not granted")
            await MainActor.run {
                appState.errorMessage = "Screen recording permission required for meeting capture"
                appState.meetingTranslationRecordingState = .error
                handleMeetingTranslationStateChange(.error)
                activeMeetingTranslationLanguagePair = nil
                activeMeetingTranslationTargetLanguage = nil
            }
            return
        }

        // Meeting translation uses cloud realtime by default
        let pair = requestedPair ?? SettingsStorage.shared.resolveTranslationLanguagePair()
        SettingsStorage.shared.markTranslationLanguagePairUsed(pair)
        activeMeetingTranslationLanguagePair = pair
        activeMeetingTranslationTargetLanguage = pair.languageB
        meetingTranslationTimestampBackfill.reset()

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
            wireMeetingRecorderStatusMessages()

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
                activeMeetingTranslationLanguagePair = nil
                activeMeetingTranslationTargetLanguage = nil
                return
            }
            await MainActor.run {
                appState.meetingTranslationRecordingState = .recording
                appState.meetingTranslationRecordingStartTime = Date()
                appState.liveTranscriptStore = store
                handleMeetingTranslationStateChange(.recording)
            }

            if let recordingId = meetingRecorderService.currentRecordingId {
                let startTime = appState.meetingTranslationRecordingStartTime ?? Date()
                let targetLanguage = activeMeetingTranslationTargetLanguage
                    ?? activeMeetingTranslationLanguagePair?.languageB
                    ?? SettingsStorage.shared.voiceTranslationTargetLanguage
                _ = RecordingsLibraryStorage.shared.beginMeetingRecording(
                    id: recordingId,
                    type: .meetingTranslation,
                    createdAt: startTime,
                    translationTargetLanguageCode: targetLanguage
                )
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
                activeMeetingTranslationLanguagePair = nil
                activeMeetingTranslationTargetLanguage = nil
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

        // Wire token callbacks. Annotate the full batch before filtering so
        // translation tokens inherit timestamps from the interleaved originals.
        rtService.onTokensReceived = { [weak self, weak store] tokens in
            guard let self else { return }
            let annotated = meetingTranslationTimestampBackfill.annotate(tokens)
            let translatedTokens = filterMeetingTranslatedTokens(annotated)
            guard !translatedTokens.isEmpty else { return }
            Task { @MainActor in
                store?.processTokens(translatedTokens)
                self.updateRecordingFeedbackTokens(translatedTokens, mode: .meetingTranslation)
            }
        }

        let connectionStatusHandler: (RealtimeConnectionStatus) -> Void = { [weak self, weak store] status in
            Task { @MainActor in
                store?.connectionStatus = status
                self?.updateRecordingFeedbackConnectionStatus(status, mode: .meetingTranslation)
                if let id = self?.meetingRecorderService.currentRecordingId {
                    let detail: String? = switch status {
                    case .connecting, .reconnecting:
                        "Reconnecting…"
                    case let .failed(message):
                        message.isEmpty
                            ? "Live transcript interrupted — audio still recording"
                            : "Live transcript interrupted — audio still recording (\(message))"
                    case .connected, .disconnected:
                        nil
                    }
                    RecordingsLibraryStorage.shared.updateStatusDetail(id: id, detail: detail)
                }
            }
        }

        rtService.onSegmentBoundary = { [weak self, weak store] _ in
            self?.meetingTranslationTimestampBackfill.reset()
            Task { @MainActor in
                store?.markSegmentBoundary()
            }
        }

        let errorHandler: (Error) -> Void = { error in
            Log.transcription.error("Realtime meeting translation error: \(error.localizedDescription)")
            // Don't stop recording — file recording continues independently
        }
        rtService.setConnectionHandlers(
            onError: errorHandler,
            onConnectionStatusChanged: connectionStatusHandler
        )

        // Connect WebSocket (recording continues even if translation socket is unavailable)
        do {
            let pair = activeMeetingTranslationLanguagePair ?? SettingsStorage.shared.resolveTranslationLanguagePair()
            let languageHints = SettingsStorage.shared.translationLanguageHints(for: pair)

            try await rtService.connect(
                languageHints: languageHints,
                strictLanguageHints: !languageHints.isEmpty,
                audioConfig: .defaultPCM16kMono,
                translationConfig: RealtimeTranslationConfig(
                    mode: .twoWay(languageA: pair.languageA, languageB: pair.languageB)
                )
            )
            await MainActor.run {
                store.isActive = true
            }
            Log.transcription
                .info(
                    "Meeting real-time translation connected successfully (\(pair.languageA.uppercased()) <-> \(pair.languageB.uppercased()))"
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
        let targetLang = activeMeetingTranslationTargetLanguage
            ?? activeMeetingTranslationLanguagePair?.languageB
            ?? SettingsStorage.shared.voiceTranslationTargetLanguage
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
        let pair = activeMeetingTranslationLanguagePair ?? SettingsStorage.shared.resolveTranslationLanguagePair()
        let targetLanguage = activeMeetingTranslationTargetLanguage
            ?? pair.languageB

        await MainActor.run {
            appState.meetingTranslationRecordingState = .processing
            handleMeetingTranslationStateChange(.processing)
        }

        // Finalize and disconnect real-time translation (if active)
        let hasRealtimeSession = await MainActor.run { appState.liveTranscriptStore != nil }
        if hasRealtimeSession {
            _ = await realtimeTranscriptionService.finalize(profile: .safe)
            await realtimeTranscriptionService.disconnect()
            meetingRecorderService.onRealtimeAudioData = nil
        }

        // Mark store as no longer active
        let store = await MainActor.run { appState.liveTranscriptStore }
        await MainActor.run {
            store?.isActive = false
        }

        // Track audio artifacts for library save and cleanup
        var capturedAudioURL: URL?
        var originalWavURL: URL?
        let stopTime = Date()
        // Capture in-progress recording ID before stopRecording() clears it (RLR-M1).
        let inProgressRecordingId = meetingRecorderService.currentRecordingId
        let recordingId = inProgressRecordingId ?? UUID()

        func cleanupTemporaryAudio() {
            if let wavURL = originalWavURL {
                try? FileManager.default.removeItem(at: wavURL)
            }
            if let audioURL = capturedAudioURL {
                try? FileManager.default.removeItem(at: audioURL)
            }
        }

        func cleanupInProgressDirectory() {
            if let ipId = inProgressRecordingId {
                Task {
                    if let store = try? InProgressRecordingStore.sharedStore() {
                        try? await store.cleanup(recordingId: ipId)
                    }
                }
            }
        }

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

                text = try await transcriptionService.translateAndTranscribe(
                    audioData: audioData,
                    languagePair: pair
                )
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
                activeMeetingTranslationLanguagePair = nil
                activeMeetingTranslationTargetLanguage = nil
            }
            Log.app.info("stopMeetingTranslationRecording: SUCCESS")

            let compressedURL = await AudioCompressionService.compressToFLAC(wavURL: audioURL)
            if compressedURL != audioURL {
                originalWavURL = audioURL
                capturedAudioURL = compressedURL
            }

            let duration = recordingStartTime.map { stopTime.timeIntervalSince($0) } ?? 0
            let hasLiveRow = RecordingsLibraryStorage.shared.recordings.contains { $0.id == recordingId }
            let saved: Bool
            if hasLiveRow {
                saved = RecordingsLibraryStorage.shared.finalizeInProgressRecording(
                    id: recordingId,
                    audioURL: compressedURL,
                    duration: duration,
                    endedAt: stopTime,
                    status: .translated,
                    forceSave: true
                )
                if saved {
                    RecordingsLibraryStorage.shared.updateRecording(
                        id: recordingId,
                        status: .translated,
                        text: text,
                        error: nil,
                        translationTargetLanguageCode: targetLanguage
                    )
                }
            } else {
                saved = RecordingsLibraryStorage.shared.saveRecording(
                    id: recordingId,
                    audioURL: compressedURL,
                    type: .meetingTranslation,
                    duration: duration,
                    transcriptionText: text,
                    translationTargetLanguageCode: targetLanguage,
                    createdAt: recordingStartTime ?? stopTime,
                    forceSave: true
                ) != nil
            }
            if saved {
                cleanupInProgressDirectory()
                RecoveryStateManager.shared.clearState()
                cleanupTemporaryAudio()
            } else if let ipId = inProgressRecordingId {
                _ = RecordingsLibraryStorage.shared.markNeedsRecovery(
                    id: ipId,
                    endedAt: stopTime,
                    durationSeconds: duration
                )
            }

            if SettingsStorage.shared.playSoundOnCompletion {
                NSSound(named: .init("Funk"))?.play()
            }

        } catch is CancellationError {
            Log.app.info("stopMeetingTranslationRecording: Cancelled")
            if let ipId = inProgressRecordingId {
                let duration = recordingStartTime.map { stopTime.timeIntervalSince($0) } ?? 0
                if let audioURL = capturedAudioURL {
                    let hasLiveRow = RecordingsLibraryStorage.shared.recordings.contains { $0.id == ipId }
                    let saved: Bool
                    if hasLiveRow {
                        saved = RecordingsLibraryStorage.shared.finalizeInProgressRecording(
                            id: ipId,
                            audioURL: audioURL,
                            duration: duration,
                            endedAt: stopTime,
                            status: .unprocessed,
                            forceSave: true
                        )
                    } else {
                        saved = false
                        _ = RecordingsLibraryStorage.shared.markNeedsRecovery(
                            id: ipId,
                            endedAt: stopTime,
                            durationSeconds: duration
                        )
                    }
                    if saved {
                        cleanupInProgressDirectory()
                        cleanupTemporaryAudio()
                        RecoveryStateManager.shared.clearState()
                    }
                } else {
                    _ = RecordingsLibraryStorage.shared.markNeedsRecovery(
                        id: ipId,
                        endedAt: stopTime,
                        durationSeconds: duration
                    )
                }
            } else {
                cleanupTemporaryAudio()
                cleanupInProgressDirectory()
                RecoveryStateManager.shared.clearState()
            }
            await MainActor.run {
                appState.meetingTranslationRecordingState = .idle
                appState.meetingTranslationRecordingStartTime = nil
                handleMeetingTranslationStateChange(.idle)
                activeMeetingTranslationLanguagePair = nil
                activeMeetingTranslationTargetLanguage = nil
            }
            return
        } catch {
            Log.app.error("Meeting translation failed: \(error)")

            if let audioURL = capturedAudioURL {
                let audioURLForLibrarySave = await AudioCompressionService.compressToFLAC(wavURL: audioURL)
                if audioURLForLibrarySave != audioURL {
                    originalWavURL = audioURL
                    capturedAudioURL = audioURLForLibrarySave
                }
                let duration = recordingStartTime.map { stopTime.timeIntervalSince($0) } ?? 0
                let hasLiveRow = RecordingsLibraryStorage.shared.recordings.contains { $0.id == recordingId }
                let saved: Bool
                if hasLiveRow {
                    saved = RecordingsLibraryStorage.shared.finalizeInProgressRecording(
                        id: recordingId,
                        audioURL: audioURLForLibrarySave,
                        duration: duration,
                        endedAt: stopTime,
                        status: .unprocessed,
                        forceSave: true
                    )
                } else {
                    saved = RecordingsLibraryStorage.shared.saveRecording(
                        id: recordingId,
                        audioURL: audioURLForLibrarySave,
                        type: .meetingTranslation,
                        duration: duration,
                        translationTargetLanguageCode: targetLanguage,
                        createdAt: recordingStartTime ?? stopTime,
                        forceSave: true
                    ) != nil
                }
                if saved {
                    cleanupInProgressDirectory()
                    cleanupTemporaryAudio()
                    RecoveryStateManager.shared.clearState()
                } else if let ipId = inProgressRecordingId {
                    _ = RecordingsLibraryStorage.shared.markNeedsRecovery(
                        id: ipId,
                        endedAt: stopTime,
                        durationSeconds: duration
                    )
                }
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
                activeMeetingTranslationLanguagePair = nil
                activeMeetingTranslationTargetLanguage = nil
            }
        }

        // End App Nap prevention
        if let token = meetingTranslationActivityToken {
            ProcessInfo.processInfo.endActivity(token)
            meetingTranslationActivityToken = nil
        }

        Log.app.info("stopMeetingTranslationRecording: END")
    }

    // MARK: - Escape Cancel Handler

    private func setupMeetingTranslationEscapeCancelHandler() {
        let escapeService = EscapeCancelService.shared
        guard SettingsStorage.shared.escapeCancelEnabled else {
            escapeService.deactivate()
            return
        }

        escapeService.onProgressEscape = { pressCount, _ in
            DictationOverlayController.shared.showInfoDuringRecording(
                message: SettingsStorage.shared.escapeCancelRepeatHint(afterPressCount: pressCount),
                mode: .meetingTranslation,
                duration: 1.5
            )
        }

        // On second shortcut press (confirmed cancel): cancel recording
        escapeService.onCancel = { [weak self] in
            Task { @MainActor in
                let shouldSaveAudio = SettingsStorage.shared.escapeCancelSaveAudio
                await self?.cancelMeetingTranslationRecording()
                let message = shouldSaveAudio ? "Recording cancelled and saved" : "Recording cancelled"
                DictationOverlayController.shared.showInfo(message: message)
            }
        }

        escapeService.activate()
    }
}
