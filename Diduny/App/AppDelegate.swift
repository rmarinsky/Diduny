import AppKit
import Combine
import LaunchAtLogin
import os
import SwiftUI

enum RecordingKind {
    case voice
    case translation
    case meeting
    case meetingTranslation

    var displayName: String {
        switch self {
        case .voice: "dictation"
        case .translation: "translation"
        case .meeting: "meeting recording"
        case .meetingTranslation: "meeting translation"
        }
    }
}

private final class SleepRecordingFlushBridge {
    private let meetingRecorderService: MeetingRecorderService
    private let stateLock = NSLock()
    private var recordingWasInterruptedBySleep = false

    var releaseActivityTokens: (() -> Void)?

    init(meetingRecorderService: MeetingRecorderService) {
        self.meetingRecorderService = meetingRecorderService
    }

    /// Flushes the active meeting recording synchronously on the willSleep thread.
    /// Voice/translation recordings hold audio in memory until stop() is called; their
    /// recovery state is already persisted on disk so there is nothing extra to flush.
    func flushActiveRecordingForSleep() -> Bool {
        let meetingActive = meetingRecorderService.isRecording

        guard meetingActive else {
            Log.recording.info("[Sleep] flushActiveRecordingForSleep: no active meeting recording")
            setRecordingWasInterruptedBySleep(false)
            return true
        }

        Log.recording.info("[Sleep] flushActiveRecordingForSleep: flushing meeting recording chunk")

        let flushedURL = meetingRecorderService.synchronousFlushForSleep()
        let flushSucceeded = flushedURL != nil
        setRecordingWasInterruptedBySleep(true)

        let recordingId = meetingRecorderService.currentRecordingId
        if let recordingId {
            // Persist the manifest synchronously before returning: the app can be
            // suspended the instant this sleep-flush returns, so a deferred async
            // write could be lost and leave recovery reading stale state after
            // wake/crash. Block on a detached task (detached → not MainActor-bound,
            // so waiting on the main thread can't deadlock the actor) with a short
            // timeout so a wedged store can't hang the sleep transition.
            let sem = DispatchSemaphore(value: 0)
            Task.detached(priority: .userInitiated) {
                defer { sem.signal() }
                do {
                    let store = try InProgressRecordingStore.sharedStore()
                    if var manifest = try await store.readManifest(for: recordingId) {
                        manifest.recordingInterruptedBySleep = true
                        manifest.lastWriteAt = Date()
                        if !manifest.chunks.isEmpty {
                            let closeTime: Date? = flushSucceeded ? Date() : nil
                            manifest.chunks[manifest.chunks.count - 1].closedAt = closeTime
                            if let url = flushedURL,
                               let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                               let size = attrs[.size] as? Int64
                            {
                                manifest.chunks[manifest.chunks.count - 1].byteCount = size
                            }
                        }
                        try await store.writeManifest(manifest, for: recordingId)
                        Log.recording
                            .info(
                                "[Sleep] manifest updated: recordingInterruptedBySleep=true, chunk closedAt=\(flushSucceeded ? "set" : "nil")"
                            )
                    }
                } catch {
                    Log.recording.error("[Sleep] Failed to update manifest: \(error.localizedDescription)")
                }
            }
            if sem.wait(timeout: .now() + 2) == .timedOut {
                Log.recording
                    .error("[Sleep] manifest update timed out (2s) — proceeding without confirmed persist")
            }
        }

        releaseActivityTokens?()
        return flushSucceeded
    }

    func consumeRecordingWasInterruptedBySleep() -> Bool {
        stateLock.lock()
        let value = recordingWasInterruptedBySleep
        recordingWasInterruptedBySleep = false
        stateLock.unlock()
        return value
    }

    private func setRecordingWasInterruptedBySleep(_ value: Bool) {
        stateLock.lock()
        recordingWasInterruptedBySleep = value
        stateLock.unlock()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    // MARK: - Properties

    let appState = AppState()

    /// Whether this process was started by the system as a login item. Captured
    /// synchronously in `applicationDidFinishLaunching` — the Apple event that
    /// carries the flag is only current during that call.
    private var launchedAtLogin = false

    /// Audio level piping to the recording feedback panel
    var audioLevelCancellable: AnyCancellable?

    // App Nap prevention tokens
    var recordingActivityToken: NSObjectProtocol?
    var meetingActivityToken: NSObjectProtocol?
    var meetingTranslationActivityToken: NSObjectProtocol?
    var translationActivityToken: NSObjectProtocol?

    // Sleep handling (RLR-M2)
    private var sleepFlushCoordinator: SleepFlushCoordinator?
    private var sleepRecordingFlushBridge: SleepRecordingFlushBridge?

    // Pipeline Tasks (stored so cancel can abort them)
    var voicePipelineTask: Task<Void, Never>?
    var translationPipelineTask: Task<Void, Never>?
    var meetingPipelineTask: Task<Void, Never>?
    var meetingPipelineGeneration: UInt64 = 0
    var activeMeetingTranscriptionSessionID: UUID?
    var activeMeetingTranscriptionProvider: TranscriptionProvider?
    var meetingTranslationPipelineTask: Task<Void, Never>?
    /// In-flight meeting realtime WS connect, launched before capture setup so
    /// the handshake overlaps it. Held so stop/cancel can abort a connect that
    /// is still in progress.
    var meetingRealtimeConnectTask: Task<Void, Never>?
    /// Batches meeting realtime tokens to ≤10Hz store updates. Held so the
    /// stop path can flush the tail before reading the transcript.
    var meetingTokenCoalescer: RealtimeTokenCoalescer?

    // Auto-reset Tasks (success/error → idle timers)
    var voiceAutoResetTask: Task<Void, Never>?
    var translationAutoResetTask: Task<Void, Never>?
    var meetingAutoResetTask: Task<Void, Never>?
    var meetingTranslationAutoResetTask: Task<Void, Never>?

    // MARK: - Services (exposed for SwiftUI access)

    lazy var updaterManager = UpdaterManager()
    lazy var audioDeviceManager = AudioDeviceManager()
    lazy var audioRecorder = AudioRecorderService()
    lazy var transcriptionService = CloudTranscriptionService()
    lazy var whisperTranscriptionService = WhisperTranscriptionService()
    lazy var clipboardService = ClipboardService()
    lazy var hotkeyService = HotkeyService()
    lazy var pushToTalkService = PushToTalkService()
    lazy var translationPushToTalkService = PushToTalkService()
    lazy var meetingRecorderService = MeetingRecorderService()
    lazy var meetingJoinMonitor = MeetingJoinMonitor()
    lazy var realtimeTranscriptionService = CloudRealtimeService()
    var localVoiceStreamingService: LocalWhisperStreamingService?
    var localMeetingStreamingService: LocalWhisperStreamingService?
    var voiceRealtimeAccumulator: RealtimeVoiceAccumulator?
    var voiceRealtimeSessionEnabled: Bool = false
    var voiceRealtimeConnectionError: String?
    var translationRealtimeAccumulator: RealtimeTranslationAccumulator?
    var translationRealtimeSessionEnabled: Bool = false
    var translationRealtimeConnectionError: String?
    var translationRealtimeConnectionTask: Task<Void, Never>?
    var activeTranslationLanguagePair: TranslationLanguagePair?
    var activeMeetingTranslationLanguagePair: TranslationLanguagePair?
    var activeTranslationTargetLanguage: String?
    var activeMeetingTranslationTargetLanguage: String?
    var meetingTranslationTimestampBackfill = TranslationTimestampBackfill()

    var activeTranscriptionService: TranscriptionServiceProtocol {
        switch SettingsStorage.shared.effectiveTranscriptionProvider {
        case .cloud: transcriptionService
        case .local: whisperTranscriptionService
        }
    }

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_: Notification) {
        launchedAtLogin = LaunchAtLogin.wasLaunchedAtLogin
        NSLog("[Diduny] applicationDidFinishLaunching: launchedAtLogin=%d", launchedAtLogin ? 1 : 0)

        let hasExistingInstallState = AuthService.hasStoredSession
            || SettingsStorage.hasPersistedFirstUseState
            || RecordingsLibraryStorage.hasPersistedLibrary
        let isFreshInstall = OnboardingManager.shared.prepareForLaunch(
            hasExistingInstallState: hasExistingInstallState
        )
        if let currentVersion = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String {
            UpdateArrivalState.shared.recordLaunch(
                version: currentVersion,
                isFreshInstall: isFreshInstall
            )
        }

        MainWindowController.shared.configure(appDelegate: self)
        EdgeCommandPanelController.shared.configure(appDelegate: self)
        OnboardingWindowController.shared.configure(appDelegate: self)

        // Start Sparkle updater (access lazy var to trigger init)
        _ = updaterManager

        // AuthService warm-up is deferred until a cloud feature needs it.
        // Permission gates use its cheap UserDefaults session-presence flag.

        setupRecordingFeedbackStopHandler()

        // Meeting starts fetch SCShareableContent (0.5-2s from the window
        // server); warm the cache now so the first start hits it. No-op until
        // screen-recording permission has been granted.
        ShareableContentCache.shared.prewarm()

        // Listen for push-to-talk key changes
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(pushToTalkKeyChanged(_:)),
            name: .pushToTalkKeyChanged,
            object: nil
        )

        // Listen for translation push-to-talk key changes
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(translationPushToTalkKeyChanged(_:)),
            name: .translationPushToTalkKeyChanged,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(pushToTalkTapCountChanged(_:)),
            name: .pushToTalkTapCountChanged,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(pushToTalkModeChanged(_:)),
            name: .pushToTalkModeChanged,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(translationPushToTalkTapCountChanged(_:)),
            name: .translationPushToTalkTapCountChanged,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(translationPushToTalkModeChanged(_:)),
            name: .translationPushToTalkModeChanged,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(pushToTalkHoldStartDelayChanged(_:)),
            name: .pushToTalkHoldStartDelayChanged,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(translationPushToTalkHoldStartDelayChanged(_:)),
            name: .translationPushToTalkHoldStartDelayChanged,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(meetingSuggestionsEnabledChanged(_:)),
            name: .meetingSuggestionsEnabledChanged,
            object: nil
        )

        setupApplicationServices()

        if OnboardingManager.shared.shouldPresentOnboardingWindow {
            OnboardingWindowController.shared.showOnboarding()
        } else {
            showMainWindowAfterLaunch()
        }
    }

    /// Runtime setup is never gated by first-use guidance.
    private func setupApplicationServices() {
        // AuthService remains lazy until first cloud use; getAccessToken()
        // refreshes an expiring session on demand.

        // Setup hotkeys and push-to-talk
        setupHotkeys()
        setupPushToTalk()
        setupTranslationPushToTalk()

        // Setup sleep handling for all recording modes (RLR-M2).
        // Must be registered before OrphanedRecordingDetector (M5a) to ensure the
        // coordinator is active if a recording is started immediately after onboarding.
        setupSleepHandling()

        // Check for orphaned recordings from previous crash
        checkForOrphanedRecordings()

        // Fetch remote config (non-blocking)
        Task {
            await RemoteConfigService.shared.fetchIfNeeded()
            if let msg = RemoteConfigService.shared.maintenanceMessage {
                DictationOverlayController.shared.showInfo(message: msg, duration: 5.0)
            }
        }

        // Avoid initializing AuthService just for this log line.
        if !AuthService.hasStoredSession {
            Log.app.info("[Auth] No stored session — cloud preferences remain stored, runtime uses local fallback")
        }

        updateMeetingJoinMonitoring()

    }

    @objc private func meetingSuggestionsEnabledChanged(_: Notification) {
        updateMeetingJoinMonitoring()
    }

    private func updateMeetingJoinMonitoring() {
        guard SettingsStorage.shared.meetingSuggestionsEnabled else {
            meetingJoinMonitor.stop()
            return
        }
        meetingJoinMonitor.start { [weak self] event in
            self?.handleMeetingPresenceEvent(event)
        }
    }

    private func handleMeetingPresenceEvent(_ event: MeetingPresenceEvent) {
        switch event {
        case let .joined(meeting):
            guard !hasAnyRecordingInProgress else { return }
            EdgeCommandPanelController.shared.showMeetingSuggestion(meeting)
        case let .ended(meeting):
            EdgeCommandPanelController.shared.dismissMeetingSuggestion(id: meeting.id)
        }
    }

    func showMainWindowAfterLaunch() {
        // Spotlight launches should surface the overview after setup, while
        // login-item launches stay menu-bar only.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(200))
            NSLog("[Diduny] setupAfterOnboarding deferred: isVisible=%d policy=%d launchedAtLogin=%d",
                  MainWindowController.shared.isVisible ? 1 : 0, NSApp.activationPolicy().rawValue,
                  launchedAtLogin ? 1 : 0)
            if !launchedAtLogin, !MainWindowController.shared.isVisible {
                MainWindowController.shared.showWindow(section: .overview)
            }
        }
    }

    private func checkForOrphanedRecordings() {
        let orphanedRecording = RecoveryStateManager.shared.hasOrphanedRecording()

        // Promote any leftover in-progress meeting directories into library needs-recovery rows.
        Task { @MainActor in
            let promotedIDs = await promoteOrphanedInProgressMeetings()
            if let managedID = orphanedRecording?.state.inProgressMeetingRecordingID,
               promotedIDs.contains(managedID),
               RecoveryStateManager.shared.loadState()?.inProgressMeetingRecordingID == managedID
            {
                RecoveryStateManager.shared.clearState()
            }
        }

        if let (state, fileExists) = orphanedRecording {
            // In-progress meeting chunks are recovered through their library row.
            // The legacy modal only knows about the first chunk and would create a
            // duplicate, incomplete recording after chunk rotation.
            if state.inProgressMeetingRecordingID != nil {
                return
            }
            if fileExists {
                Log.app.info("Found orphaned recording from \(state.startTime)")
                showRecoveryAlert(for: state)
            } else {
                // File doesn't exist, just clear the state
                RecoveryStateManager.shared.clearState()
            }
        }
    }

    /// Ensures every on-disk `InProgressRecordings/<id>/` has a `.needsRecovery` library row.
    private func promoteOrphanedInProgressMeetings() async -> Set<UUID> {
        guard let store = try? InProgressRecordingStore.sharedStore() else { return [] }
        return await promoteOrphanedInProgressMeetings(
            store: store,
            storage: RecordingsLibraryStorage.shared
        )
    }

    func promoteOrphanedInProgressMeetings(
        store: InProgressRecordingStore,
        storage: RecordingsLibraryStorage
    ) async -> Set<UUID> {
        guard let ids = try? await store.allInProgressRecordingIDs() else { return [] }
        var promotedIDs = Set<UUID>()
        for id in ids {
            if let existing = storage.recordings.first(where: { $0.id == id }) {
                if existing.status == .needsRecovery
                    || (existing.status == .recording && storage.markNeedsRecovery(id: id))
                {
                    promotedIDs.insert(id)
                }
                continue
            }
            // No library row yet (pre-live-row builds or begin failed) — synthesize one.
            let manifest = try? await store.readManifest(for: id)
            let type: Recording.RecordingType = switch manifest?.type {
            case .meetingTranslation: .meetingTranslation
            default: .meeting
            }
            let startedAt = manifest?.startedAt ?? Date()
            guard storage.beginMeetingRecording(id: id, type: type, createdAt: startedAt) != nil else {
                continue
            }
            let endedAt = manifest?.lastWriteAt ?? Date()
            let duration = max(0, endedAt.timeIntervalSince(startedAt))
            if storage.markNeedsRecovery(id: id, endedAt: endedAt, durationSeconds: duration) {
                promotedIDs.insert(id)
            }
        }
        return promotedIDs
    }

    nonisolated static func recoveryDuration(startedAt: Date?, endedAt: Date) -> TimeInterval? {
        startedAt.map { max(0, endedAt.timeIntervalSince($0)) }
    }

    // MARK: - Sleep Handling (RLR-M2)

    private func setupSleepHandling() {
        let coordinator = SleepFlushCoordinator()
        let bridge = SleepRecordingFlushBridge(meetingRecorderService: meetingRecorderService)

        bridge.releaseActivityTokens = { [weak self] in
            Task { @MainActor [weak self] in
                self?.releaseMeetingSleepActivityTokens()
            }
        }

        coordinator.flushCurrentChunk = { [weak bridge] in
            bridge?.flushActiveRecordingForSleep() ?? true
        }

        coordinator.onWake = { [weak bridge, weak self] in
            guard bridge?.consumeRecordingWasInterruptedBySleep() == true else { return }
            Task { @MainActor [weak self] in
                self?.showWakeAfterRecordingInterrupt()
            }
        }

        sleepRecordingFlushBridge = bridge
        sleepFlushCoordinator = coordinator
        Log.app.info("[Sleep] SleepFlushCoordinator registered for willSleep / didWake")
    }

    private func releaseMeetingSleepActivityTokens() {
        if let token = meetingActivityToken {
            ProcessInfo.processInfo.endActivity(token)
            meetingActivityToken = nil
        }
        if let token = meetingTranslationActivityToken {
            ProcessInfo.processInfo.endActivity(token)
            meetingTranslationActivityToken = nil
        }
    }

    private func showWakeAfterRecordingInterrupt() {
        Log.recording.info("[Sleep] wake after recording interrupt — surfacing feedback message")

        DictationOverlayController.shared.showInfo(
            message: "Recording stopped. Open Recordings to recover audio.",
            duration: 5.0
        )
        // Transition recording states to idle so the UI is consistent.
        // Promote the live library row to needs-recovery; keep InProgressRecordings.
        let endedAt = Date()
        if appState.meetingRecordingState == .recording {
            if let id = meetingRecorderService.currentRecordingId {
                let start = appState.meetingRecordingStartTime
                let duration = Self.recoveryDuration(startedAt: start, endedAt: endedAt)
                _ = RecordingsLibraryStorage.shared.markNeedsRecovery(
                    id: id,
                    endedAt: endedAt,
                    durationSeconds: duration
                )
            }
            appState.meetingRecordingState = .idle
            appState.meetingRecordingStartTime = nil
            handleMeetingStateChange(.idle)
        }
        if appState.meetingTranslationRecordingState == .recording {
            if let id = meetingRecorderService.currentRecordingId {
                let start = appState.meetingTranslationRecordingStartTime
                let duration = Self.recoveryDuration(startedAt: start, endedAt: endedAt)
                _ = RecordingsLibraryStorage.shared.markNeedsRecovery(
                    id: id,
                    endedAt: endedAt,
                    durationSeconds: duration
                )
            }
            appState.meetingTranslationRecordingState = .idle
            appState.meetingTranslationRecordingStartTime = nil
            handleMeetingTranslationStateChange(.idle)
        }
    }

    private func showRecoveryAlert(for state: RecoveryState) {
        let alert = NSAlert()
        alert.messageText = "Recover Previous Recording?"
        alert.informativeText = "An incomplete \(state.recordingType.displayName) recording was found from \(formatDate(state.startTime)). Would you like to process it now?"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Process")
        alert.addButton(withTitle: "Discard")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            recoverRecording(from: state)
        } else {
            discardRecovery(state: state)
        }
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func recoverRecording(from state: RecoveryState) {
        Task {
            var recoveredRecordingID: UUID?
            let processor = RecoveryRecordingProcessor(
                save: { audioData, state, duration in
                    let recordingID = RecordingsLibraryStorage.shared.saveRecording(
                        audioData: audioData,
                        type: state.recordingType.libraryType,
                        duration: duration,
                        createdAt: state.startTime,
                        recoverySource: .orphanedSession,
                        forceSave: true
                    )
                    recoveredRecordingID = recordingID
                    return recordingID
                },
                update: { recordingID, status, text, error in
                    RecordingsLibraryStorage.shared.updateRecording(
                        id: recordingID,
                        status: status,
                        text: text,
                        error: error
                    )
                },
                cleanupSource: { state in
                    try? FileManager.default.removeItem(atPath: state.tempFilePath)
                    RecoveryStateManager.shared.clearState()
                }
            )

            do {
                let result = try await processor.process(state: state) { audioData, recordingType in
                    Log.app.info("Recovered audio data: \(audioData.count) bytes")
                    let rawText: String
                    switch recordingType {
                    case .voice:
                        rawText = try await self.activeTranscriptionService.transcribe(audioData: audioData)
                    case .meeting:
                        if SettingsStorage.shared.effectiveTranscriptionProvider == .cloud {
                            rawText = try await self.transcriptionService.transcribeMeeting(audioData: audioData)
                        } else {
                            rawText = try await self.whisperTranscriptionService.transcribe(audioData: audioData)
                        }
                    case .translation, .meetingTranslation:
                        let service: TranscriptionServiceProtocol = SettingsStorage.shared
                            .effectiveTranslationProvider == .local
                            ? self.whisperTranscriptionService : self.transcriptionService
                        rawText = try await service.translateAndTranscribe(audioData: audioData)
                    }

                    return await TranscriptCleanupService.shared.clean(
                        rawText,
                        fillerWords: SettingsStorage.shared.fillerWords
                    )
                }

                let copyBehavior: ClipboardCopyBehavior = switch state.recordingType {
                case .voice, .translation:
                    .cleaned
                case .meeting, .meetingTranslation:
                    .raw
                }

                clipboardService.copy(text: result.text, behavior: copyBehavior)
                Log.app.info("Recovery transcription successful")
                MainWindowController.shared.showRecording(id: result.recordingID)

                if SettingsStorage.shared.playSoundOnCompletion {
                    NSSound(named: .init("Funk"))?.play()
                }
            } catch {
                Log.app.error("Recovery transcription failed: \(error.localizedDescription)")
                if let recoveredRecordingID {
                    MainWindowController.shared.showRecording(id: recoveredRecordingID)
                    DictationOverlayController.shared.showInfo(
                        message: "Recording recovered. Transcription can be retried from Recordings.",
                        duration: 5
                    )
                } else {
                    DictationOverlayController.shared.showInfo(
                        message: "Recovery failed. The original audio was kept for another attempt.",
                        duration: 5
                    )
                }
            }
        }
    }

    private func discardRecovery(state: RecoveryState) {
        try? FileManager.default.removeItem(atPath: state.tempFilePath)
        RecoveryStateManager.shared.clearState()
        Log.app.info("Orphaned recording discarded")
    }

    /// Called when the app is already running and the user activates it again
    /// (Spotlight press Enter, Dock click). If no windows are visible, open
    /// the main window so the UI actually appears.
    func applicationShouldHandleReopen(_: NSApplication, hasVisibleWindows: Bool) -> Bool {
        NSLog("[Diduny] applicationShouldHandleReopen: hasVisibleWindows=%d", hasVisibleWindows)
        if !hasVisibleWindows {
            NSLog("[Diduny] applicationShouldHandleReopen: calling showWindow")
            MainWindowController.shared.showWindow()
        }
        return true
    }

    func applicationWillTerminate(_: Notification) {
        meetingJoinMonitor.stop()
        hotkeyService.unregisterAll()
        pushToTalkService.stop()
        translationPushToTalkService.stop()
        NotificationCenter.default.removeObserver(self)
        // Release all activity tokens on termination to avoid leaking wake locks.
        if let token = recordingActivityToken { ProcessInfo.processInfo.endActivity(token) }
        if let token = translationActivityToken { ProcessInfo.processInfo.endActivity(token) }
        if let token = meetingActivityToken { ProcessInfo.processInfo.endActivity(token) }
        if let token = meetingTranslationActivityToken { ProcessInfo.processInfo.endActivity(token) }
        sleepFlushCoordinator = nil
    }

    func loadAudioData(from url: URL) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            try Data(contentsOf: url)
        }.value
    }

    // MARK: - Shared Recording Helpers

    func wireDeviceLostNotification() {
        audioRecorder.onDeviceLost = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if self.appState.translationRecordingState == .recording {
                    self.showRecordingInfoDuringActiveRecording(
                        message: "Microphone disconnected",
                        mode: .translation(targetLanguage: self.translationPairLabel),
                        duration: 2.0
                    )
                } else if self.appState.recordingState == .recording {
                    self.showRecordingInfoDuringActiveRecording(
                        message: "Microphone disconnected",
                        mode: .voice,
                        duration: 2.0
                    )
                } else {
                    DictationOverlayController.shared.showInfo(message: "Microphone disconnected", duration: 2.0)
                }
            }
        }
    }

    // MARK: - Cross-Mode Recording Guard

    private func setupRecordingFeedbackStopHandler() {
        DictationOverlayController.shared.setStopHandler { [weak self] in
            await self?.stopActiveRecordingFromFeedback()
        }
        NotchManager.shared.setStopHandler { [weak self] in
            await self?.stopActiveRecordingFromFeedback()
        }
    }

    func stopActiveRecordingFromFeedback() async {
        if appState.meetingTranslationRecordingState == .recording {
            await stopMeetingTranslationRecording()
            return
        }
        if appState.meetingTranslationRecordingState == .processing,
           appState.meetingTranslationRecordingStartTime == nil
        {
            await cancelMeetingTranslationRecording()
            return
        }

        if appState.meetingRecordingState == .recording {
            await stopMeetingRecording()
            return
        }
        if appState.meetingRecordingState == .processing,
           appState.meetingRecordingStartTime == nil
        {
            let cancellationTask = cancelMeetingPipeline()
            await cancellationTask?.value
            return
        }

        if appState.translationRecordingState == .recording {
            await stopTranslationRecording()
            return
        }
        if appState.translationRecordingState == .processing,
           appState.translationRecordingStartTime == nil
        {
            await cancelTranslationRecording()
            return
        }

        if appState.recordingState == .recording {
            await stopRecording()
            return
        }
        if appState.recordingState == .processing,
           appState.recordingStartTime == nil
        {
            await cancelRecording()
            return
        }

        Log.app.info("stopActiveRecordingFromFeedback: no active recording state")
    }

    private func isStateInProgress(_ state: RecordingState) -> Bool {
        state == .recording || state == .processing
    }

    var hasAnyRecordingInProgress: Bool {
        isStateInProgress(appState.recordingState)
            || isStateInProgress(appState.translationRecordingState)
            || isStateInProgress(appState.meetingRecordingState)
            || isStateInProgress(appState.meetingTranslationRecordingState)
    }

    private func restoreRecordingFeedbackAfterInfo(delay: TimeInterval = 1.6) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self else { return }

            if appState.meetingTranslationRecordingState == .recording {
                showFeedbackRecording(mode: .meetingTranslation)
                return
            }
            if appState.meetingTranslationRecordingState == .processing {
                showFeedbackProcessing(mode: .meetingTranslation)
                return
            }

            if appState.meetingRecordingState == .recording {
                showFeedbackRecording(mode: .meeting)
                return
            }
            if appState.meetingRecordingState == .processing {
                showFeedbackProcessing(mode: .meeting)
                return
            }

            let translationMode: RecordingMode = .translation(targetLanguage: translationPairLabel)
            if appState.translationRecordingState == .recording {
                showFeedbackRecording(mode: translationMode)
                return
            }
            if appState.translationRecordingState == .processing {
                showFeedbackProcessing(mode: translationMode)
                return
            }

            if appState.recordingState == .recording {
                showFeedbackRecording(mode: .voice)
                return
            }
            if appState.recordingState == .processing {
                showFeedbackProcessing(mode: .voice)
            }
        }
    }

    func wireMeetingRecorderStatusMessages() {
        meetingRecorderService.onStatusMessage = { [weak self] message in
            Task { @MainActor in
                DictationOverlayController.shared.showInfo(message: message, duration: 2.0)
                self?.restoreRecordingFeedbackAfterInfo(delay: 2.1)
            }
        }

        meetingRecorderService.onError = { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                self.appState.errorMessage = error.localizedDescription
                self.appState.liveTranscriptStore?.isActive = false
                self.appState.liveTranscriptStore = nil

                if self.isStateInProgress(self.appState.meetingTranslationRecordingState) {
                    self.appState.meetingTranslationRecordingState = .error
                    self.appState.meetingTranslationRecordingStartTime = nil
                    self.handleMeetingTranslationStateChange(.error)
                } else if self.isStateInProgress(self.appState.meetingRecordingState) {
                    self.appState.meetingRecordingState = .error
                    self.appState.meetingRecordingStartTime = nil
                    self.handleMeetingStateChange(.error)
                }

                DictationOverlayController.shared.showError(message: error.localizedDescription)
            }
        }
    }

    private func isSettingsWindowVisible() -> Bool {
        NSApp.windows.contains { window in
            window.identifier?.rawValue == "com_apple_SwiftUI_Settings_window" && window.isVisible
        }
    }

    func refreshActivationPolicy() {
        let shouldShowInAppSwitcher = isStateInProgress(appState.meetingRecordingState)
            || MainWindowController.shared.isVisible
            || isSettingsWindowVisible()
        NSApp.setActivationPolicy(shouldShowInAppSwitcher ? .regular : .accessory)
    }

    func canStartRecording(kind: RecordingKind) -> Bool {
        var blockers: [RecordingKind] = []

        if kind != .voice, isStateInProgress(appState.recordingState) {
            blockers.append(.voice)
        }
        if kind != .translation, isStateInProgress(appState.translationRecordingState) {
            blockers.append(.translation)
        }
        if kind != .meeting, isStateInProgress(appState.meetingRecordingState) {
            blockers.append(.meeting)
        }
        if kind != .meetingTranslation, isStateInProgress(appState.meetingTranslationRecordingState) {
            blockers.append(.meetingTranslation)
        }

        guard !blockers.isEmpty else { return true }

        let blockersText = blockers.map(\.displayName).joined(separator: ", ")
        Log.app.warning("Cannot start \(kind.displayName) while \(blockersText) is in progress")
        if let activeMode = activeFeedbackMode(for: blockers.first) {
            showRecordingInfoDuringActiveRecording(
                message: "Stop current recording first",
                mode: activeMode,
                duration: 1.5
            )
        } else {
            DictationOverlayController.shared.showInfo(message: "Stop current recording first", duration: 1.5)
        }
        restoreRecordingFeedbackAfterInfo()

        return false
    }

    private func activeFeedbackMode(for kind: RecordingKind?) -> RecordingMode? {
        switch kind {
        case .voice:
            .voice
        case .translation:
            .translation(targetLanguage: translationPairLabel)
        case .meeting:
            .meeting
        case .meetingTranslation:
            .meetingTranslation
        case nil:
            nil
        }
    }

    private func startDate(for mode: RecordingMode) -> Date? {
        switch mode {
        case .voice:
            appState.recordingStartTime
        case .translation:
            appState.translationRecordingStartTime
        case .meeting:
            appState.meetingRecordingStartTime
        case .meetingTranslation:
            appState.meetingTranslationRecordingStartTime
        case .fileTranscription:
            nil
        }
    }

    private func showFeedbackRecording(mode: RecordingMode) {
        DictationOverlayController.shared.startRecording(mode: mode)
    }

    private func showFeedbackProcessing(mode: RecordingMode) {
        if startDate(for: mode) == nil {
            DictationOverlayController.shared.begin(mode: mode)
        } else {
            DictationOverlayController.shared.startFinalizing(mode: mode)
        }
    }

    private func showFeedbackSuccess(text: String, mode _: RecordingMode) {
        DictationOverlayController.shared.showSuccess(text: text)
    }

    private func showFeedbackError(message: String, mode _: RecordingMode) {
        DictationOverlayController.shared.showError(message: message)
    }

    private func hideFeedback(mode _: RecordingMode) {
        DictationOverlayController.shared.hide()
    }

    func updateRecordingFeedbackAudioLevel(_ level: Float, mode _: RecordingMode) {
        DictationOverlayController.shared.updateAudioLevel(level)
    }

    func updateRecordingFeedbackTokens(_ tokens: [RealtimeToken], mode _: RecordingMode) {
        DictationOverlayController.shared.processTokens(tokens)
    }

    func markRecordingFeedbackSegmentBoundary(mode _: RecordingMode) {
        DictationOverlayController.shared.markSegmentBoundary()
    }

    func updateRecordingFeedbackConnectionStatus(_ status: RealtimeConnectionStatus, mode _: RecordingMode) {
        DictationOverlayController.shared.updateConnectionStatus(status)
    }

    func showRecordingInfoDuringActiveRecording(
        message: String,
        mode: RecordingMode,
        duration: TimeInterval = 1.5
    ) {
        DictationOverlayController.shared.showInfoDuringRecording(
            message: message,
            mode: mode,
            duration: duration
        )
    }

    func showRecordingFeedbackInfo(
        message: String,
        mode _: RecordingMode,
        duration: TimeInterval = 1.5
    ) {
        DictationOverlayController.shared.showInfo(message: message, duration: duration)
    }

    func startAudioRecorderWithFallback(
        initialDevice: AudioDevice,
        logPrefix: String
    ) async throws -> AudioDevice {
        do {
            try await audioRecorder.startRecording(device: initialDevice)
            return initialDevice
        } catch let error as AudioTimeoutError {
            throw error
        } catch {
            let fallbackDevices = recordingFallbackDevices(afterFailing: initialDevice)
            guard !fallbackDevices.isEmpty else {
                throw error
            }

            Log.app.warning("\(logPrefix): primary microphone failed, trying fallback routes")

            var lastError: Error = error
            for fallbackDevice in fallbackDevices {
                do {
                    try await audioRecorder.startRecording(device: fallbackDevice)
                    let warningMessage = initialDevice.isDefault
                        ? "System Default microphone failed to start. Using \(fallbackDevice.name)."
                        : "\(initialDevice.name) failed to start. Using \(fallbackDevice.name)."
                    appState.deviceFallbackWarning = warningMessage
                    Log.app.warning("\(logPrefix): recovered by switching microphone route")
                    return fallbackDevice
                } catch let timeout as AudioTimeoutError {
                    throw timeout
                } catch {
                    lastError = error
                }
            }

            throw lastError
        }
    }

    private func recordingFallbackDevices(afterFailing failedDevice: AudioDevice) -> [AudioDevice] {
        audioDeviceManager.refreshDevices()
        let alternatives = audioDeviceManager.availableDevices.filter { $0.uid != failedDevice.uid }
        guard !alternatives.isEmpty else { return [] }

        var ordered: [AudioDevice] = []

        if !failedDevice.isDefault,
           let defaultDevice = alternatives.first(where: \.isDefault)
        {
            ordered.append(defaultDevice)
        }

        ordered.append(contentsOf: alternatives.filter(\.isBuiltInMic))
        ordered.append(contentsOf: alternatives.filter {
            !$0.isBuiltInMic && !$0.isBluetooth && !$0.isDefault
        })
        ordered.append(contentsOf: alternatives.filter(\.isBluetooth))
        ordered.append(contentsOf: alternatives)

        var seen = Set<String>()
        return ordered.filter { seen.insert($0.uid).inserted }
    }

    // MARK: - State Change Handlers

    // Note: These are called directly from recording methods after state changes
    // Since @Observable doesn't use Combine publishers like ObservableObject

    private func handleStateChange(
        _ state: RecordingState,
        mode: RecordingMode,
        currentStateGetter: @escaping () -> RecordingState,
        stateResetter: @escaping (RecordingState) -> Void,
        autoResetTaskSetter: @escaping (Task<Void, Never>?) -> Void,
        successDelay: TimeInterval,
        errorDelay: TimeInterval
    ) {
        // Cancel any previous auto-reset timer for this mode
        autoResetTaskSetter(nil)

        switch state {
        case .recording:
            showFeedbackRecording(mode: mode)
        case .processing:
            showFeedbackProcessing(mode: mode)
        case .success:
            if let text = appState.lastTranscription {
                showFeedbackSuccess(text: text, mode: mode)
            } else {
                hideFeedback(mode: mode)
            }
            let task = Task {
                try? await Task.sleep(for: .seconds(successDelay))
                guard !Task.isCancelled else { return }
                if currentStateGetter() == .success {
                    stateResetter(.idle)
                }
            }
            autoResetTaskSetter(task)
        case .error:
            showFeedbackError(message: appState.errorMessage ?? "Error", mode: mode)
            let task = Task {
                try? await Task.sleep(for: .seconds(errorDelay))
                guard !Task.isCancelled else { return }
                if currentStateGetter() == .error {
                    stateResetter(.idle)
                }
            }
            autoResetTaskSetter(task)
        case .idle:
            hideFeedback(mode: mode)
        }
    }

    func handleRecordingStateChange(_ state: RecordingState) {
        voiceAutoResetTask?.cancel()
        handleStateChange(
            state,
            mode: .voice,
            currentStateGetter: { self.appState.recordingState },
            stateResetter: { self.appState.recordingState = $0 },
            autoResetTaskSetter: { self.voiceAutoResetTask = $0 },
            successDelay: 1.5,
            errorDelay: 2.0
        )
    }

    func handleMeetingStateChange(_ state: RecordingState) {
        // Belt-and-braces: an error mid-meeting must never leave the global
        // Escape key monitor installed (stop/cancel paths deactivate it
        // themselves; error paths reach here). Meeting .error implies meeting
        // was the active mode, so no other mode's monitor can be live.
        if state == .error {
            EscapeCancelService.shared.deactivate()
        }
        meetingAutoResetTask?.cancel()
        handleStateChange(
            state,
            mode: .meeting,
            currentStateGetter: { self.appState.meetingRecordingState },
            stateResetter: { self.appState.meetingRecordingState = $0 },
            autoResetTaskSetter: { self.meetingAutoResetTask = $0 },
            successDelay: 2.0,
            errorDelay: 2.0
        )
        refreshActivationPolicy()
    }

    func handleMeetingTranslationStateChange(_ state: RecordingState) {
        meetingTranslationAutoResetTask?.cancel()
        handleStateChange(
            state,
            mode: .meetingTranslation,
            currentStateGetter: { self.appState.meetingTranslationRecordingState },
            stateResetter: { self.appState.meetingTranslationRecordingState = $0 },
            autoResetTaskSetter: { self.meetingTranslationAutoResetTask = $0 },
            successDelay: 2.0,
            errorDelay: 2.0
        )
    }

    var translationTargetLanguage: String {
        activeTranslationLanguagePair?.languageB
            ?? activeTranslationTargetLanguage
            ?? SettingsStorage.shared.defaultTranslationLanguagePair.languageB
    }

    var translationTargetLabel: String {
        translationTargetLanguage.uppercased()
    }

    var translationTargetDisplayName: String {
        SupportedLanguage.language(for: translationTargetLanguage)?.name ?? translationTargetLabel
    }

    var translationPairLabel: String {
        (activeTranslationLanguagePair ?? SettingsStorage.shared.defaultTranslationLanguagePair).displayLabel
    }

    func handleTranslationStateChange(_ state: RecordingState) {
        translationAutoResetTask?.cancel()
        handleStateChange(
            state,
            mode: .translation(targetLanguage: translationPairLabel),
            currentStateGetter: { self.appState.translationRecordingState },
            stateResetter: { self.appState.translationRecordingState = $0 },
            autoResetTaskSetter: { self.translationAutoResetTask = $0 },
            successDelay: 1.5,
            errorDelay: 2.0
        )
    }

    // MARK: - Settings

    func openMainWindow(section: MainSection = .overview) {
        MainWindowController.shared.showWindow(section: section)
    }

    func openSettings(tab: MainSection = .general) {
        openMainWindow(section: tab)
    }
}
