import AppKit
import Foundation

// MARK: - Meeting Recording

extension AppDelegate {
    @objc func toggleMeetingRecording() {
        let provider: TranscriptionProvider = SettingsStorage.shared.meetingRealtimeTranscriptionEnabled
            ? .cloud
            : .local
        toggleMeetingRecording(provider: provider)
    }

    func toggleMeetingRecording(
        provider: TranscriptionProvider,
        cancelPipeline: (() async -> Void)? = nil
    ) {
        let meetingRecordingState = appState.meetingRecordingState
        Log.app.info("toggleMeetingRecording called, current state: \(meetingRecordingState)")

        // Task ownership: the stop pipeline runs inside meetingPipelineTask,
        // so a blanket cancel here would kill an in-flight stop (transcription
        // upload included) and silently drop the meeting. Only the explicit
        // cancel-while-processing branch may cancel it — from outside the
        // task being cancelled.
        switch meetingRecordingState {
        case .idle:
            guard canStartRecording(kind: .meeting) else { return }
            meetingPipelineGeneration &+= 1
            ShareableContentCache.shared.prewarm()
            if provider == .cloud {
                Task { _ = await AuthService.shared.getAccessToken() }
            }
            meetingPipelineTask?.cancel()
            appState.meetingRecordingState = .processing
            handleMeetingStateChange(.processing)
            meetingPipelineTask = Task {
                await self.startMeetingRecording(provider: provider)
            }
        case .recording:
            meetingPipelineTask = Task {
                await self.stopMeetingRecording()
            }
        case .processing:
            Log.app.info("Meeting state is processing, canceling...")
            cancelMeetingPipeline(cancelPipeline: cancelPipeline)
        default:
            Log.app.info("Meeting state is \(meetingRecordingState), ignoring toggle")
        }
    }

    @discardableResult
    func cancelMeetingPipeline(
        cancelPipeline: (() async -> Void)? = nil
    ) -> Task<Void, Never>? {
        let state = appState.meetingRecordingState
        guard state == .processing || state == .recording else { return nil }

        let cancellationGeneration = meetingPipelineGeneration
        let inFlightTask = meetingPipelineTask
        inFlightTask?.cancel()
        let cancellationTask = Task {
            if let inFlightTask {
                await inFlightTask.value
            }
            let currentState = self.appState.meetingRecordingState
            guard !Task.isCancelled,
                  currentState == .processing || currentState == .recording,
                  self.meetingPipelineGeneration == cancellationGeneration
            else { return }
            if let cancelPipeline {
                await cancelPipeline()
            } else {
                await self.cancelMeetingRecording()
            }
        }
        meetingPipelineTask = cancellationTask
        return cancellationTask
    }

    /// Tears down an active or processing meeting recording. Callers that need
    /// to abort an in-flight pipeline task must cancel it themselves before
    /// calling — this method must never cancel the task it may be running in
    /// (self-cancel made the save-audio-on-cancel branch fail silently).
    func cancelMeetingRecording() async {
        Log.app.info("cancelMeetingRecording: BEGIN")
        defer {
            activeMeetingTranscriptionSessionID = nil
            activeMeetingTranscriptionProvider = nil
        }

        let recordingStartTime = appState.meetingRecordingStartTime
        let stopTime = Date()

        // Deactivate chapter bookmark hotkey
        hotkeyService.unregisterChapterHotkey()

        // Deactivate escape cancel handler
        EscapeCancelService.shared.deactivate()

        // Disconnect real-time transcription (if active or still connecting).
        _ = await stopMeetingLiveTranscription()

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
                            type: .meeting,
                            duration: duration,
                            createdAt: recordingStartTime ?? stopTime,
                            forceSave: true
                        ) != nil
                    }
                    // Only clean up after durable library handoff.
                    if saved, let ipId = cancelInProgressRecordingId {
                        if let store = try? InProgressRecordingStore.sharedStore() {
                            try? await store.cleanup(recordingId: ipId)
                        }
                        try? FileManager.default.removeItem(at: audioURL)
                        Log.app.info("cancelMeetingRecording: audio saved after cancel")
                    } else if !saved {
                        Log.app.warning("cancelMeetingRecording: library save failed — keeping in-progress audio")
                        if let ipId = cancelInProgressRecordingId {
                            _ = RecordingsLibraryStorage.shared.markNeedsRecovery(
                                id: ipId,
                                endedAt: stopTime,
                                durationSeconds: duration
                            )
                        }
                    }
                } else {
                    await meetingRecorderService.cancelRecording()
                    if let ipId = cancelInProgressRecordingId {
                        await discardLiveMeetingRow(id: ipId)
                    }
                }
            } catch {
                Log.app
                    .warning("cancelMeetingRecording: failed to save audio on cancel - \(error.localizedDescription)")
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

    nonisolated static func resolveMeetingTranscriptionProvider(
        requestedProvider: TranscriptionProvider,
        hasStoredSession: Bool,
        cachedUsage: UsageResponse?
    ) -> TranscriptionProvider {
        requestedProvider == .cloud
            && UsageService.canOfferCloudTranscription(
                hasStoredSession: hasStoredSession,
                usage: cachedUsage
            ) ? .cloud : .local
    }

    func startMeetingRecording(
        provider requestedProvider: TranscriptionProvider,
        ensureScreenRecordingPermission: @escaping () async -> Bool = {
            await PermissionManager.shared.ensureScreenRecordingPermission(context: .meetingRecording)
        },
        startRecorder: (() async throws -> Void)? = nil
    ) async {
        Log.app.info("startMeetingRecording: BEGIN")

        guard !Task.isCancelled, canStartRecording(kind: .meeting) else {
            Log.app.info("startMeetingRecording: blocked by another active recording mode")
            return
        }

        let sessionID = UUID()
        activeMeetingTranscriptionSessionID = sessionID
        let provider = Self.resolveMeetingTranscriptionProvider(
            requestedProvider: requestedProvider,
            hasStoredSession: AuthService.hasStoredSession,
            cachedUsage: UsageService.shared.cachedUsage
        )
        activeMeetingTranscriptionProvider = provider
        var didStart = false
        defer {
            if !didStart, activeMeetingTranscriptionSessionID == sessionID {
                activeMeetingTranscriptionSessionID = nil
                activeMeetingTranscriptionProvider = nil
            }
        }

        // Request screen capture permission on-demand
        let hasPermission = await ensureScreenRecordingPermission()
        guard !Task.isCancelled,
              activeMeetingTranscriptionSessionID == sessionID,
              appState.meetingRecordingState == .processing
        else {
            Log.app.info("startMeetingRecording: canceled during permission request")
            return
        }
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

        let cloudModeEnabled = provider == .cloud

        // Timed from after the permission check (which can block on a user
        // prompt) to the .recording state transition.
        let startMetrics = ConnectMetrics(label: "[Meeting] start")
        defer { startMetrics.finish() }

        // Prevent App Nap during meeting recording
        meetingActivityToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "Meeting recording in progress"
        )

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

            // Wire realtime transcription and start connecting BEFORE capture
            // setup, so the WS handshake overlaps ScreenCaptureKit/mic startup
            // instead of running after it. Audio captured before the socket is
            // up is buffered by CloudRealtimeService and flushed on connect —
            // recording never waits for the network.
            guard !Task.isCancelled, activeMeetingTranscriptionSessionID == sessionID else { return }
            let store = await setupMeetingLiveTranscription(cloudModeEnabled: cloudModeEnabled)
            let stillOwnsSession = activeMeetingTranscriptionSessionID == sessionID
            guard !Task.isCancelled,
                  stillOwnsSession,
                  appState.meetingRecordingState == .processing
            else {
                if stillOwnsSession {
                    _ = await stopMeetingLiveTranscription()
                    if let token = meetingActivityToken {
                        ProcessInfo.processInfo.endActivity(token)
                        meetingActivityToken = nil
                    }
                }
                return
            }

            startMetrics.begin(.recorderStart)
            if let startRecorder {
                try await startRecorder()
            } else {
                try await meetingRecorderService.startRecording()
            }
            startMetrics.end(.recorderStart)
            Log.app.info("Meeting recording started")

            // Only set recording state AFTER confirmed working
            let recordingStateAfterStart = appState.meetingRecordingState
            let ownsSessionAfterRecorderStart = activeMeetingTranscriptionSessionID == sessionID
            guard !Task.isCancelled,
                  ownsSessionAfterRecorderStart,
                  recordingStateAfterStart == .processing
            else {
                Log.app
                    .warning(
                        "startMeetingRecording: state changed during init (now \(recordingStateAfterStart)), aborting"
                    )
                if ownsSessionAfterRecorderStart {
                    _ = await stopMeetingLiveTranscription()
                    await meetingRecorderService.cancelRecording()
                    if let token = meetingActivityToken {
                        ProcessInfo.processInfo.endActivity(token)
                        meetingActivityToken = nil
                    }
                }
                return
            }
            await MainActor.run {
                appState.meetingRecordingState = .recording
                appState.meetingRecordingStartTime = Date()
                appState.liveTranscriptStore = store
                handleMeetingStateChange(.recording)
                if !cloudModeEnabled {
                    updateRecordingFeedbackConnectionStatus(.connected, mode: .meeting)
                }
            }
            didStart = true

            // Library row from start — same UUID as InProgressRecordingStore.
            if let recordingId = meetingRecorderService.currentRecordingId {
                let startTime = appState.meetingRecordingStartTime ?? Date()
                let deviceInfo = meetingRecorderService.microphoneDevice.map {
                    RecordingDeviceInfo(
                        uid: $0.uid,
                        name: $0.name,
                        transportType: $0.transportType.displayName,
                        sampleRate: $0.sampleRate,
                        channelCount: $0.inputChannels,
                        wasDefaultRoute: $0.isDefault
                    )
                }
                _ = RecordingsLibraryStorage.shared.beginMeetingRecording(
                    id: recordingId,
                    type: .meeting,
                    createdAt: startTime,
                    sourceDevice: deviceInfo
                )
            }

            startMetrics.finish(outcome: "ok")

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
            guard activeMeetingTranscriptionSessionID == sessionID else { return }
            if Task.isCancelled {
                _ = await stopMeetingLiveTranscription()
                await meetingRecorderService.cancelRecording()
                if let token = meetingActivityToken {
                    ProcessInfo.processInfo.endActivity(token)
                    meetingActivityToken = nil
                }
                return
            }
            Log.app.error("Meeting recording failed: \(error)")

            // Abort the in-flight realtime connect — nothing will consume it.
            _ = await stopMeetingLiveTranscription()

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

    func setupMeetingLiveTranscription(cloudModeEnabled: Bool) async -> LiveTranscriptStore {
        if cloudModeEnabled {
            return await setupRealtimeTranscription(sessionID: activeMeetingTranscriptionSessionID)
        }

        guard SettingsStorage.shared.meetingLocalLivePreviewEnabled else {
            Log.app.info("Local meeting mode selected — live preview disabled, recording only")
            return LiveTranscriptStore()
        }

        Log.app.info("Local meeting mode selected — starting live Whisper preview")
        let store = LiveTranscriptStore()
        store.isActive = true
        store.connectionStatus = .connected

        let whisper = whisperTranscriptionService
        let stream = LocalWhisperStreamingService(
            transcribe: { samples in
                try await whisper.transcribeRawSamples(samples)
            },
            onText: { [weak self, store] text in
                let tokens = [RealtimeToken(text: text, isFinal: false)]
                await store.processTokens(tokens)
                await self?.updateRecordingFeedbackTokens(tokens, mode: .meeting)
            },
            onError: { [weak self, store] error in
                Log.whisper.warning("Local meeting preview failed: \(error.localizedDescription)")
                await MainActor.run {
                    store.connectionStatus = .failed("Live preview unavailable")
                }
                await self?.updateRecordingFeedbackConnectionStatus(
                    .failed("Live preview unavailable"),
                    mode: .meeting
                )
            }
        )

        localMeetingStreamingService = stream
        meetingRecorderService.onRealtimeAudioData = { [weak stream] pcmData in
            Task { await stream?.appendPCM16(pcmData) }
        }
        return store
    }

    @discardableResult
    func stopMeetingLiveTranscription(finalizeCloud: Bool = false) async -> Bool {
        meetingRealtimeConnectTask?.cancel()
        meetingRealtimeConnectTask = nil

        if let localMeetingStreamingService {
            meetingRecorderService.onRealtimeAudioData = nil
            self.localMeetingStreamingService = nil
            await localMeetingStreamingService.stop()
            appState.liveTranscriptStore?.connectionStatus = .disconnected
            return true
        }

        var didReceiveFinalization = true
        if finalizeCloud, appState.liveTranscriptStore != nil {
            let result = await realtimeTranscriptionService.finalize(profile: .safe)
            didReceiveFinalization = result.didReceiveFinishedSignal
        }
        await realtimeTranscriptionService.disconnect()
        realtimeTranscriptionService.clearCallbacks()
        meetingRecorderService.onRealtimeAudioData = nil
        await meetingTokenCoalescer?.flushNow()
        meetingTokenCoalescer = nil
        return didReceiveFinalization
    }

    private func setupRealtimeTranscription(sessionID: UUID?) async -> LiveTranscriptStore {
        let store = await MainActor.run { LiveTranscriptStore() }

        let rtService = realtimeTranscriptionService

        // Stream the exact same mixed mono audio that is written to fallback WAV.
        meetingRecorderService.onRealtimeAudioData = { [weak rtService] pcmData in
            rtService?.sendAudioData(pcmData)
        }

        // Wire token callbacks. Batches are coalesced to ≤10Hz before touching
        // the @Observable store — per-message main-actor updates made SwiftUI
        // re-render for every WS message and lag grew with the meeting.
        let coalescer = RealtimeTokenCoalescer { [weak self, weak store] events in
            for event in events {
                switch event {
                case let .tokens(tokens):
                    store?.processTokens(tokens)
                    self?.updateRecordingFeedbackTokens(tokens, mode: .meeting)
                case .segmentBoundary:
                    store?.markSegmentBoundary()
                    self?.markRecordingFeedbackSegmentBoundary(mode: .meeting)
                }
            }
        }
        meetingTokenCoalescer = coalescer
        rtService.onTokensReceived = { [weak coalescer] tokens in
            coalescer?.add(tokens)
        }

        let connectionStatusHandler: (RealtimeConnectionStatus) -> Void = { [weak self, weak store] status in
            Task { @MainActor in
                self?.applyMeetingRealtimeConnectionStatus(
                    status,
                    sessionID: sessionID,
                    store: store
                )
            }
        }

        // Boundaries go through the coalescer so they stay ordered relative to
        // the token batches it is still holding.
        rtService.onSegmentBoundary = { [weak coalescer] boundary in
            coalescer?.addBoundary(boundary)
        }

        let errorHandler: (Error) -> Void = { [weak self] error in
            Log.transcription.error("Realtime transcription error: \(error.localizedDescription)")
            Task { @MainActor in
                self?.fallBackMeetingToLocalIfUsageUnavailable(error, sessionID: sessionID)
            }
            // Don't stop recording — file recording continues independently
        }
        rtService.setConnectionHandlers(
            onError: errorHandler,
            onConnectionStatusChanged: connectionStatusHandler
        )

        // Connect in the background — recording start never waits for the
        // network, and CloudRealtimeService buffers audio until the socket is
        // up. On failure the recording continues (async transcription fallback
        // on stop); the store's connectionStatus reflects progress in the UI.
        meetingRealtimeConnectTask?.cancel()
        meetingRealtimeConnectTask = Task { [weak self, weak store] in
            guard let self else { return }
            do {
                let languageHints = SettingsStorage.shared.speechLanguageHints
                try await realtimeTranscriptionService.connect(
                    languageHints: languageHints,
                    strictLanguageHints: !languageHints.isEmpty
                )
                await MainActor.run {
                    store?.isActive = true
                }
                Log.transcription.info("Meeting real-time transcription connected successfully")
            } catch {
                Log.transcription.error(
                    "Meeting real-time transcription FAILED to connect: \(error.localizedDescription)"
                )
                // Stop/cancel paths abort this task; don't overwrite the store
                // state they are tearing down.
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    store?.isActive = true
                    store?.connectionStatus = .failed(error.localizedDescription)
                }
                fallBackMeetingToLocalIfUsageUnavailable(error, sessionID: sessionID)
            }
        }

        return store
    }

    @discardableResult
    func applyMeetingRealtimeConnectionStatus(
        _ status: RealtimeConnectionStatus,
        sessionID: UUID?,
        store: LiveTranscriptStore?
    ) -> Bool {
        guard let sessionID, activeMeetingTranscriptionSessionID == sessionID else { return false }
        store?.connectionStatus = status
        updateRecordingFeedbackConnectionStatus(status, mode: .meeting)
        if let id = meetingRecorderService.currentRecordingId {
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
        return true
    }

    @discardableResult
    func fallBackMeetingToLocalIfUsageUnavailable(_ error: Error, sessionID: UUID?) -> Bool {
        guard let sessionID,
              activeMeetingTranscriptionSessionID == sessionID,
              activeMeetingTranscriptionProvider == .cloud,
              case .usageLimitExceeded = error as? RealtimeTranscriptionError
        else { return false }
        activeMeetingTranscriptionProvider = .local
        meetingRecorderService.onRealtimeAudioData = nil
        Log.app.info("Meeting transcription switched from Cloud to Local after usage rejection")
        return true
    }

    // MARK: - Stop Meeting Recording

    @discardableResult
    static func enqueueLocalMeetingTranscriptionIfReady(
        savedRecordingID: UUID?,
        cloudModeEnabled: Bool,
        hasLocalModel: Bool,
        enqueue: ([UUID], RecordingQueueService.QueueAction, TranscriptionProvider?) -> Void
    ) -> Bool {
        guard let savedRecordingID, !cloudModeEnabled, hasLocalModel else { return false }
        enqueue([savedRecordingID], .transcribe, .local)
        return true
    }

    func addMeetingChapter() {
        guard appState.meetingRecordingState == .recording,
              let startTime = appState.meetingRecordingStartTime else { return }
        let elapsed = Date().timeIntervalSince(startTime)
        let chapterNumber = appState.meetingChapters.count + 1
        let chapter = MeetingChapter(timestampSeconds: elapsed, label: "Chapter \(chapterNumber)")
        appState.meetingChapters.append(chapter)
        DictationOverlayController.shared.showInfo(message: "Chapter \(chapterNumber) added", duration: 1.0)
        Log.app.info("Meeting chapter \(chapterNumber) added at \(elapsed)s")
    }

    func stopMeetingRecording() async {
        // Reentry guard: a second stop request (double-pressed shortcut, panel
        // button + shortcut) must not run the teardown pipeline twice. The
        // state flips to .processing synchronously below, so the next caller
        // lands in the cancel-while-processing branch instead.
        guard appState.meetingRecordingState == .recording else {
            let ignoredState = appState.meetingRecordingState
            Log.app.info("stopMeetingRecording: ignored, state is \(ignoredState)")
            return
        }

        Log.app.info("stopMeetingRecording: BEGIN")
        defer {
            activeMeetingTranscriptionSessionID = nil
            activeMeetingTranscriptionProvider = nil
        }

        // Deactivate chapter bookmark hotkey
        hotkeyService.unregisterChapterHotkey()

        // Deactivate escape cancel handler
        EscapeCancelService.shared.deactivate()

        // Capture recording start time for duration calculation
        let recordingStartTime = appState.meetingRecordingStartTime

        appState.meetingRecordingState = .processing
        handleMeetingStateChange(.processing)

        // Finalize and disconnect real-time transcription (if active)
        let didReceiveRealtimeFinalization = await stopMeetingLiveTranscription(finalizeCloud: true)

        // Next meeting start should hit a warm SCShareableContent cache.
        ShareableContentCache.shared.prewarm()

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
        let duration = recordingStartTime.map { stopTime.timeIntervalSince($0) } ?? 0
        // Capture in-progress recording ID before stopRecording() clears it (RLR-M1).
        // Library row created at start uses this same UUID.
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

        // Whether the early library save succeeded (nil when the retention
        // policy skips saving) — read by the catch paths below.
        var librarySavedId: UUID?

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

            // Finalize the live library row (same UUID as start). Fall back to
            // saveRecording when beginMeetingRecording never created a row.
            let hasLiveRow = RecordingsLibraryStorage.shared.recordings.contains { $0.id == recordingId }
            if hasLiveRow {
                let ok = RecordingsLibraryStorage.shared.finalizeInProgressRecording(
                    id: recordingId,
                    audioURL: compressedURL,
                    duration: duration,
                    endedAt: stopTime,
                    status: .processing,
                    forceSave: true
                )
                librarySavedId = ok ? recordingId : nil
            } else {
                librarySavedId = RecordingsLibraryStorage.shared.saveRecording(
                    id: recordingId,
                    audioURL: compressedURL,
                    type: .meeting,
                    duration: duration,
                    createdAt: recordingStartTime ?? stopTime,
                    forceSave: true
                )
                if librarySavedId != nil {
                    RecordingsLibraryStorage.shared.updateRecording(
                        id: recordingId,
                        status: .processing,
                        error: nil
                    )
                }
            }
            if librarySavedId == nil, let ipId = inProgressRecordingId {
                _ = RecordingsLibraryStorage.shared.markNeedsRecovery(
                    id: ipId,
                    endedAt: stopTime,
                    durationSeconds: duration
                )
            }

            let realtimeText = await MainActor.run { store?.finalTranscriptText ?? "" }
            var cloudModeEnabled = activeMeetingTranscriptionProvider == .cloud
            let shouldUseRealtimeText = cloudModeEnabled
                && shouldAcceptRealtimeTranscript(
                    realtimeText,
                    duration: duration,
                    didReceiveFinalization: didReceiveRealtimeFinalization
                )

            let rawTranscript: GeneratedTranscript?
            if shouldUseRealtimeText {
                rawTranscript = GeneratedTranscript(text: realtimeText)
                Log.app.info("Using real-time transcript (\(realtimeText.count) chars)")
            } else if cloudModeEnabled {
                if !realtimeText.isEmpty {
                    Log.app
                        .warning(
                            "Ignoring partial real-time transcript (\(realtimeText.count) chars, finalized=\(didReceiveRealtimeFinalization)); falling back to async jobs API"
                        )
                }
                Log.app.info("No real-time transcript, falling back to async jobs API...")

                let asyncJobService = AsyncTranscriptionJobService()
                let hints = SettingsStorage.shared.speechLanguageHints
                var config: [String: Any] = [
                    "mode": "transcribe",
                    "enable_speaker_diarization": true
                ]
                if !hints.isEmpty {
                    config["language_hints"] = hints
                    config["language_hints_strict"] = true
                }

                do {
                    rawTranscript = try await asyncJobService.transcribeFileDetailedWithRetry(
                        audioFileURL: compressedURL,
                        config: config,
                        source: compressedURL.lastPathComponent,
                        sourceDurationSeconds: duration
                    ) { status in
                        Task { @MainActor in
                            switch status.status {
                            case .queued:
                                DictationOverlayController.shared.showInfo(message: "Queued...", duration: 30)
                            case .uploading:
                                DictationOverlayController.shared.showInfo(message: "Uploading...", duration: 30)
                            case .processing:
                                // Processing can take tens of minutes for large files —
                                // use persistent processing state instead of auto-dismissing info
                                DictationOverlayController.shared.startProcessing(mode: .meeting)
                            case .finalizing:
                                DictationOverlayController.shared.showInfo(message: "Finishing up...", duration: 30)
                            default:
                                break
                            }
                        }
                    }
                    Log.app.info("Async jobs transcription received (\(rawTranscript?.text.count ?? 0) chars)")
                } catch let error as TranscriptionError where error.isUsageLimitExceeded {
                    cloudModeEnabled = false
                    activeMeetingTranscriptionProvider = .local
                    rawTranscript = nil
                    Log.app.info("Cloud usage unavailable at stop; queued Local transcription instead")
                }
            } else {
                rawTranscript = nil
                Log.app.info("Saving meeting recording without automatic transcription")
            }

            // Apply server-side cleanup (filler words, dedup, formatting).
            // Falls back to raw text silently if no auth / no network.
            let text: String? = if let rawTranscript {
                if rawTranscript.segments.contains(where: { $0.speaker != nil }) {
                    // Cleanup accepts plain text and can discard diarization structure.
                    TimedTranscriptRenderer.render(
                        segments: rawTranscript.segments,
                        fallbackText: rawTranscript.text
                    )
                } else {
                    await TranscriptCleanupService.shared.clean(
                        rawTranscript.text,
                        fillerWords: SettingsStorage.shared.fillerWords
                    )
                }
            } else {
                nil
            }

            let processingState = appState.meetingRecordingState
            guard processingState == .processing else {
                Log.app
                    .warning(
                        "stopMeetingRecording: state changed during processing (now \(processingState)), dropping result"
                    )
                if librarySavedId != nil {
                    RecordingsLibraryStorage.shared.updateRecording(
                        id: recordingId,
                        status: .unprocessed,
                        error: nil
                    )
                }
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

            }
            Log.app.info("stopMeetingRecording: SUCCESS")

            if let savedRecordingID = librarySavedId {
                if let text {
                    let segments = rawTranscript?.segments
                    RecordingsLibraryStorage.shared.completeTranscription(
                        id: recordingId,
                        status: .transcribed,
                        text: text,
                        segments: segments?.isEmpty == false ? segments : nil,
                        kind: .cloud,
                        provider: TranscriptionProvider.cloud.rawValue
                    )
                } else {
                    RecordingsLibraryStorage.shared.updateRecording(
                        id: recordingId,
                        status: .unprocessed,
                        error: nil
                    )

                    let didEnqueue = Self.enqueueLocalMeetingTranscriptionIfReady(
                        savedRecordingID: savedRecordingID,
                        cloudModeEnabled: cloudModeEnabled,
                        hasLocalModel: WhisperModelManager.shared.selectedModel() != nil
                    ) { recordingIDs, action, provider in
                        RecordingQueueService.shared.enqueue(
                            recordingIDs,
                            action: action,
                            providerOverride: provider
                        )
                    }
                    if !cloudModeEnabled, !didEnqueue {
                        DictationOverlayController.shared.showInfo(
                            message: String(localized: "Recording saved. Download a local model in Settings to transcribe it."),
                            duration: 3.0
                        )
                    }
                }
            }
            // The pipeline is done reading compressedURL — the in-progress
            // directory (which contains it) can go now only after durable handoff.
            if librarySavedId != nil {
                cleanupInProgressDirectory()
                if didCompress {
                    try? FileManager.default.removeItem(at: audioURL)
                }
                try? FileManager.default.removeItem(at: compressedURL)
                RecoveryStateManager.shared.clearState()
            }

            if SettingsStorage.shared.playSoundOnCompletion {
                NSSound(named: .init("Funk"))?.play()
            }

        } catch is CancellationError {
            Log.app.info("stopMeetingRecording: Cancelled")
            // The library entry (saved right after compression) stays — a
            // cancelled transcription must not throw away the meeting audio.
            // updateRecording is a no-op when the entry was never saved.
            if librarySavedId != nil {
                RecordingsLibraryStorage.shared.updateRecording(
                    id: recordingId,
                    status: .unprocessed,
                    error: nil
                )
                cleanupTemporaryAudio()
                cleanupInProgressDirectory()
                RecoveryStateManager.shared.clearState()
            } else if let ipId = inProgressRecordingId {
                _ = RecordingsLibraryStorage.shared.markNeedsRecovery(
                    id: ipId,
                    endedAt: stopTime,
                    durationSeconds: duration
                )
            }
            await MainActor.run {
                appState.meetingRecordingState = .idle
                appState.meetingRecordingStartTime = nil
                handleMeetingStateChange(.idle)
            }
            return
        } catch {
            Log.app.error("Meeting transcription failed: \(error)")

            if librarySavedId != nil {
                RecordingsLibraryStorage.shared.updateRecording(
                    id: recordingId,
                    status: .failed,
                    error: error.localizedDescription
                )
                cleanupInProgressDirectory()
                cleanupTemporaryAudio()
                RecoveryStateManager.shared.clearState()
            } else if let audioURL = capturedAudioURL {
                let duration = recordingStartTime.map { stopTime.timeIntervalSince($0) } ?? 0
                let hasLiveRow = RecordingsLibraryStorage.shared.recordings.contains { $0.id == recordingId }
                let saved: Bool
                if hasLiveRow {
                    saved = RecordingsLibraryStorage.shared.finalizeInProgressRecording(
                        id: recordingId,
                        audioURL: audioURL,
                        duration: duration,
                        endedAt: stopTime,
                        status: .unprocessed,
                        forceSave: true
                    )
                } else {
                    saved = RecordingsLibraryStorage.shared.saveRecording(
                        id: recordingId,
                        audioURL: audioURL,
                        type: .meeting,
                        duration: duration,
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

    private func shouldAcceptRealtimeTranscript(
        _ text: String,
        duration: TimeInterval,
        didReceiveFinalization: Bool
    ) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if didReceiveFinalization { return true }

        // Short recordings often stop before Soniox emits an explicit finished frame.
        // For longer meetings, a tiny unfinalized transcript is usually partial and
        // should fall back to the async jobs pipeline for a complete result. Measure
        // visible content (trimmed) so a whitespace-padded transcript can't masquerade
        // as substantial.
        guard duration >= 30 else { return true }
        return trimmed.count >= 120
    }

    // MARK: - Escape Cancel Handler

    private func setupMeetingEscapeCancelHandler() {
        let escapeService = EscapeCancelService.shared
        guard SettingsStorage.shared.escapeCancelEnabled else {
            escapeService.deactivate()
            return
        }

        escapeService.onProgressEscape = { pressCount, _ in
            DictationOverlayController.shared.showInfoDuringRecording(
                message: SettingsStorage.shared.escapeCancelRepeatHint(afterPressCount: pressCount),
                mode: .meeting,
                duration: 1.5
            )
        }

        // On second shortcut press (confirmed cancel): cancel recording
        escapeService.onCancel = { [weak self] in
            Task { @MainActor in
                let shouldSaveAudio = SettingsStorage.shared.escapeCancelSaveAudio
                let cancellationTask = self?.cancelMeetingPipeline()
                await cancellationTask?.value
                let message = shouldSaveAudio ? "Recording cancelled and saved" : "Recording cancelled"
                DictationOverlayController.shared.showInfo(message: message)
            }
        }

        escapeService.activate()
    }

    /// Removes the live library row and in-progress directory after an explicit discard cancel.
    func discardLiveMeetingRow(id: UUID) async {
        if let recording = RecordingsLibraryStorage.shared.recordings.first(where: { $0.id == id }) {
            guard RecordingsLibraryStorage.shared.deleteCancelledInProgressRecording(recording) else {
                NSLog("[Diduny] Failed to discard cancelled meeting recording")
                return
            }
            return
        }
        if let store = try? InProgressRecordingStore.sharedStore() {
            try? await store.cleanup(recordingId: id)
        }
    }
}
