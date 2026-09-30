import AppKit
import Foundation
import Observation

private actor AsyncPermitPool {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    private var availablePermits: Int
    private var waiters: [Waiter] = []

    init(limit: Int) {
        availablePermits = limit
    }

    func acquire() async throws {
        try Task.checkCancellation()
        if availablePermits > 0 {
            availablePermits -= 1
            return
        }

        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                waiters.append(Waiter(id: waiterID, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancel(waiterID: waiterID) }
        }
    }

    func release() {
        if waiters.isEmpty {
            availablePermits += 1
        } else {
            waiters.removeFirst().continuation.resume()
        }
    }

    private func cancel(waiterID: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == waiterID }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}

private enum RemotePreflightOutcome {
    case metadata(UUID, RemoteMediaMetadata)
    case authorizationRequired
    case failed(UUID, String)
}

struct FileTranscriptionSettingsSnapshot {
    let provider: TranscriptionProvider
    let languageHints: [String]
    let localModelName: String

    @MainActor
    static func current() -> Self {
        let settings = SettingsStorage.shared
        return Self(
            provider: .local,
            languageHints: settings.speechLanguageHints,
            localModelName: settings.selectedWhisperModel
        )
    }
}

struct ImportedMediaIdentity: Codable, Equatable {
    let fileName: String
    let fileSizeBytes: Int64?

    init(sourceURL: URL) {
        fileName = sourceURL.lastPathComponent
        let size = try? sourceURL.resourceValues(forKeys: [.fileSizeKey]).fileSize
        fileSizeBytes = size.flatMap(Int64.init)
    }
}

struct BatchTranscriptionItem: Codable, Identifiable, Equatable {
    enum RemoteArtifactWork: Codable, Equatable {
        case all
        case captionsOnly
        case transcriptOnly
    }

    enum Status: Codable, Equatable {
        case queued
        case checkingLink
        case checkingDuplicate
        case retrievingCaptions
        case downloading
        case preparing
        case uploading
        case processing
        case finalizing
        case completed
        case partialResult
        case duplicate
        case authorizationPaused
        case failed
        case cancelled

        var isTerminal: Bool {
            switch self {
            case .completed, .partialResult, .duplicate, .failed, .cancelled:
                true
            default:
                false
            }
        }

        var showsInBatchInspector: Bool {
            self != .completed && self != .duplicate
        }
    }

    let id: UUID
    let sourceURL: URL
    let sourceIdentity: ImportedMediaIdentity
    let remoteSource: YouTubeRemoteMediaSource?
    var remoteMetadata: RemoteMediaMetadata?
    var durationSeconds: TimeInterval?
    var status: Status
    var transcriptionText: String?
    var recordingID: UUID?
    var errorMessage: String?
    var progressFraction: Double?
    var downloadedBytes: Int64?
    var totalDownloadBytes: Int64?
    var sourceCaptionArtifacts: [TranscriptArtifact] = []
    var captionErrorMessage: String?
    var remoteArtifactWork: RemoteArtifactWork = .all
    var downloadedAudioURL: URL?
    var cloudJobID: String?
    /// Selection used by the persisted job; nil denotes the full source.
    var cloudJobTrimRange: AudioTrimRange?
    var startedAt: Date?
    var finishedAt: Date?

    init(id: UUID = UUID(), sourceURL: URL) {
        self.id = id
        self.sourceURL = sourceURL
        sourceIdentity = ImportedMediaIdentity(sourceURL: sourceURL)
        remoteSource = nil
        status = .queued
    }

    init(id: UUID = UUID(), remoteSource: YouTubeRemoteMediaSource) {
        self.id = id
        sourceURL = remoteSource.canonicalURL
        sourceIdentity = ImportedMediaIdentity(sourceURL: remoteSource.canonicalURL)
        self.remoteSource = remoteSource
        status = .queued
    }

    var displayName: String {
        remoteMetadata?.source.title
            ?? (remoteSource == nil ? sourceURL.lastPathComponent : sourceURL.absoluteString)
    }

    func elapsedTime(at date: Date) -> TimeInterval? {
        guard let startedAt else { return nil }
        return max(0, (finishedAt ?? date).timeIntervalSince(startedAt))
    }
}

struct BatchTranscriptionDuplicate: Equatable {
    let recordingID: UUID
    let transcriptionText: String?
    let durationSeconds: TimeInterval
    let sourceCaptionArtifacts: [TranscriptArtifact]

    init(
        recordingID: UUID,
        transcriptionText: String?,
        durationSeconds: TimeInterval,
        sourceCaptionArtifacts: [TranscriptArtifact] = []
    ) {
        self.recordingID = recordingID
        self.transcriptionText = transcriptionText
        self.durationSeconds = durationSeconds
        self.sourceCaptionArtifacts = sourceCaptionArtifacts
    }
}

@MainActor
protocol FileTranscriptionBatchPreparing: AnyObject {
    func prepare(sourceURL: URL) async throws -> ImportedMediaAudioPreparer.PreparedAudio
}

extension ImportedMediaAudioPreparer: FileTranscriptionBatchPreparing {}

@MainActor
protocol FileTranscriptionBatchTranscribing: AnyObject {
    func preflightError(for settings: FileTranscriptionSettingsSnapshot) -> String?
    func transcribe(
        audioFileURL: URL,
        settings: FileTranscriptionSettingsSnapshot,
        source: String,
        sourceDurationSeconds: TimeInterval?,
        resumeJobID: String?,
        onJobSubmitted: @escaping (String) -> Void,
        onUpdate: @escaping (JobProgressUpdate) -> Void
    ) async throws -> GeneratedTranscript
}

@MainActor
protocol FileTranscriptionBatchRecordingStoring: AnyObject {
    func completedDuplicate(sourceIdentity: ImportedMediaIdentity) -> BatchTranscriptionDuplicate?
    func completedDuplicate(remoteProvider: String, mediaID: String) -> BatchTranscriptionDuplicate?
    func completedDuplicate(remoteMetadata: RemoteMediaSourceMetadata, durationSeconds: TimeInterval)
        -> BatchTranscriptionDuplicate?
    func savePreparedAudio(
        at audioURL: URL,
        durationSeconds: TimeInterval,
        sourceIdentity: ImportedMediaIdentity
    ) -> UUID?
    func savePreparedAudio(
        at audioURL: URL,
        durationSeconds: TimeInterval,
        remoteMetadata: RemoteMediaSourceMetadata,
        sourceCaptionArtifacts: [TranscriptArtifact]
    ) -> UUID?
    func audioFileURL(recordingID: UUID) -> URL?
    func storedRecording(recordingID: UUID) -> Recording?
    func markProcessing(recordingID: UUID)
    func markCompleted(
        recordingID: UUID,
        transcript: GeneratedTranscript,
        provenance: GeneratedTranscriptProvenance?
    )
    func markFailed(recordingID: UUID, error: String)
    func markUnprocessed(recordingID: UUID)
    func updateSourceCaptionArtifacts(recordingID: UUID, artifacts: [TranscriptArtifact])
}

extension FileTranscriptionBatchRecordingStoring {
    func storedRecording(recordingID _: UUID) -> Recording? { nil }

    func completedDuplicate(remoteProvider _: String, mediaID _: String) -> BatchTranscriptionDuplicate? {
        nil
    }

    func completedDuplicate(
        remoteMetadata _: RemoteMediaSourceMetadata,
        durationSeconds _: TimeInterval
    ) -> BatchTranscriptionDuplicate? {
        nil
    }

    func updateSourceCaptionArtifacts(recordingID _: UUID, artifacts _: [TranscriptArtifact]) {}

    func savePreparedAudio(
        at audioURL: URL,
        durationSeconds: TimeInterval,
        remoteMetadata: RemoteMediaSourceMetadata,
        sourceCaptionArtifacts _: [TranscriptArtifact]
    ) -> UUID? {
        savePreparedAudio(
            at: audioURL,
            durationSeconds: durationSeconds,
            sourceIdentity: ImportedMediaIdentity(sourceURL: remoteMetadata.canonicalURL)
        )
    }
}

@MainActor
protocol FileTranscriptionBatchPersisting: AnyObject {
    func createBatch(name: String, description: String, recordingIDs: [UUID]) throws -> UUID
    func addRecordingIDs(_ recordingIDs: [UUID], to batchID: UUID) throws
    func replaceRecordingIDs(_ recordingIDs: [UUID], in batchID: UUID) throws
    func replaceWorkItems(_ items: [BatchTranscriptionItem], in batchID: UUID) throws
    func reopenBatch(_ batchID: UUID) throws
    func closeBatch(_ batchID: UUID) throws
}

extension TranscriptionBatchStorage: FileTranscriptionBatchPersisting {
    func createBatch(name: String, description: String, recordingIDs: [UUID]) throws -> UUID {
        try create(
            name: name,
            description: description,
            recordingIDs: recordingIDs
        ).id
    }

    func closeBatch(_ batchID: UUID) throws {
        try close(batchID: batchID)
    }

    func reopenBatch(_ batchID: UUID) throws {
        try reopen(batchID: batchID)
    }
}

@Observable
@MainActor
final class FileTranscriptionBatchService {
    static let cloudConcurrencyLimit = 3

    static let shared = FileTranscriptionBatchService(
        preparer: ImportedMediaAudioPreparer(),
        transcriber: LiveFileTranscriptionBatchTranscriber(),
        recordingStore: LiveFileTranscriptionBatchRecordingStore(),
        remoteExtractor: BundledRemoteMediaExtractor(),
        chromeProfile: {
            BrowserSessionStore.selected(
                from: BrowserSessionStore.discover(),
                selectionID: SettingsStorage.shared.selectedBrowserSessionID,
                legacyChromeProfileID: SettingsStorage.shared.selectedChromeProfileID
            )
        },
        remoteMediaAuthorized: {
            SettingsStorage.shared.remoteMediaRightsAcknowledged
        },
        batchPersistence: TranscriptionBatchStorage.shared,
        settingsSnapshot: { .current() },
        playCompletionSound: {
            guard SettingsStorage.shared.playSoundOnCompletion else { return }
            NSSound(named: .init("Funk"))?.play()
        }
    )

    private(set) var items: [BatchTranscriptionItem] = []
    private(set) var isProcessing = false
    private(set) var activeItemIDs: Set<UUID> = []
    private(set) var batchError: String?

    var finishedCount: Int {
        items.count(where: { $0.status.isTerminal })
    }

    var completedCount: Int {
        items.count(where: { $0.status == .completed || $0.status == .duplicate })
    }

    var duplicateCount: Int {
        items.count(where: { $0.status == .duplicate })
    }

    var failedCount: Int {
        items.count(where: { $0.status == .failed })
    }

    var partialResultCount: Int {
        items.count(where: { $0.status == .partialResult })
    }

    var isAuthorizationPaused: Bool {
        items.contains(where: { $0.status == .authorizationPaused })
    }

    var progress: Double {
        guard !items.isEmpty else { return 0 }
        return Double(finishedCount) / Double(items.count)
    }

    var activeCount: Int {
        activeItemIDs.count
    }

    var activeBatchID: UUID? {
        currentBatchID
    }

    func isActive(_ itemID: UUID) -> Bool {
        activeItemIDs.contains(itemID)
    }

    private let preparer: FileTranscriptionBatchPreparing
    private let transcriber: FileTranscriptionBatchTranscribing
    private let recordingStore: FileTranscriptionBatchRecordingStoring
    private let batchPersistence: FileTranscriptionBatchPersisting?
    private let remoteExtractor: RemoteMediaExtracting?
    private let chromeProfile: @MainActor () -> ChromeProfile?
    private let remoteMediaAuthorized: @MainActor () -> Bool
    private let settingsSnapshot: @MainActor () -> FileTranscriptionSettingsSnapshot
    private let playCompletionSound: @MainActor () -> Void

    private var processingTask: Task<Void, Never>?
    private var currentBatchID: UUID?
    private(set) var lastCreatedBatchID: UUID?
    private var initialRecordingIDs: [UUID] = []
    private var activeSettingsSnapshot: FileTranscriptionSettingsSnapshot?
    private var hasPlayedCompletionSound = false
    private var schedulerContinuation: CheckedContinuation<Void, Never>?
    private let remoteAcquisitionPermits = AsyncPermitPool(limit: 2)
    private let remoteMetadataPermits = AsyncPermitPool(limit: 3)
    private let cloudTranscriptionPermits = AsyncPermitPool(
        limit: FileTranscriptionBatchService.cloudConcurrencyLimit
    )
    private let localTranscriptionPermits = AsyncPermitPool(limit: 1)

    init(
        preparer: FileTranscriptionBatchPreparing,
        transcriber: FileTranscriptionBatchTranscribing,
        recordingStore: FileTranscriptionBatchRecordingStoring,
        remoteExtractor: RemoteMediaExtracting? = nil,
        chromeProfile: @escaping @MainActor () -> ChromeProfile? = { nil },
        remoteMediaAuthorized: @escaping @MainActor () -> Bool = { true },
        batchPersistence: FileTranscriptionBatchPersisting? = nil,
        settingsSnapshot: @escaping @MainActor () -> FileTranscriptionSettingsSnapshot,
        playCompletionSound: @escaping @MainActor () -> Void
    ) {
        self.preparer = preparer
        self.transcriber = transcriber
        self.recordingStore = recordingStore
        self.batchPersistence = batchPersistence
        self.remoteExtractor = remoteExtractor
        self.chromeProfile = chromeProfile
        self.remoteMediaAuthorized = remoteMediaAuthorized
        self.settingsSnapshot = settingsSnapshot
        self.playCompletionSound = playCompletionSound
    }

    @discardableResult
    func beginBatch(urls: [URL]) -> Bool {
        beginBatch(urls: urls, name: "", description: "", existingRecordingIDs: [])
    }

    @discardableResult
    func beginBatch(
        urls: [URL],
        name: String,
        description: String,
        existingRecordingIDs: [UUID]
    ) -> Bool {
        beginBatch(
            urls: urls,
            remoteSources: [],
            name: name,
            description: description,
            existingRecordingIDs: existingRecordingIDs
        )
    }

    @discardableResult
    func beginBatch(remoteSources: [YouTubeRemoteMediaSource]) -> Bool {
        beginBatch(
            remoteSources: remoteSources,
            name: "",
            description: "",
            existingRecordingIDs: []
        )
    }

    @discardableResult
    func beginBatch(
        remoteSources: [YouTubeRemoteMediaSource],
        name: String,
        description: String,
        existingRecordingIDs: [UUID]
    ) -> Bool {
        beginBatch(
            urls: [],
            remoteSources: remoteSources,
            name: name,
            description: description,
            existingRecordingIDs: existingRecordingIDs
        )
    }

    @discardableResult
    func beginBatch(
        urls: [URL],
        remoteSources: [YouTubeRemoteMediaSource],
        name: String,
        description: String,
        existingRecordingIDs: [UUID]
    ) -> Bool {
        guard !isProcessing else { return false }
        guard !urls.isEmpty || !remoteSources.isEmpty || !existingRecordingIDs.isEmpty else {
            return false
        }
        if !remoteSources.isEmpty {
            guard remoteMediaAuthorized() else {
                batchError = "Confirm that you own this content or have permission to transcribe it."
                return false
            }
            guard chromeProfile() != nil else {
                batchError = "Select a browser session to transcribe YouTube URLs."
                return false
            }
        }
        resetFinishedBatchIfNeeded()
        guard currentBatchID == nil else { return false }
        guard createPersistentBatch(
            name: name,
            description: description,
            existingRecordingIDs: existingRecordingIDs
        ) else { return false }
        add(urls: urls)
        add(remoteSources: remoteSources)
        startIfNeeded()
        finalizePersistentBatchIfFinished()
        return true
    }

    @discardableResult
    func append(
        to batch: TranscriptionBatch,
        urls: [URL],
        remoteSources: [YouTubeRemoteMediaSource],
        existingRecordingIDs: [UUID]
    ) -> Bool {
        guard !urls.isEmpty || !remoteSources.isEmpty || !existingRecordingIDs.isEmpty else {
            return false
        }
        if !remoteSources.isEmpty {
            guard remoteMediaAuthorized() else {
                batchError = "Confirm that you own this content or have permission to transcribe it."
                return false
            }
            guard chromeProfile() != nil else {
                batchError = "Select a browser session to transcribe YouTube URLs."
                return false
            }
        }
        if let currentBatchID {
            guard currentBatchID == batch.id else { return false }
            do {
                try batchPersistence?.addRecordingIDs(existingRecordingIDs, to: batch.id)
            } catch {
                batchError = "Could not update the transcription batch."
                return false
            }
            initialRecordingIDs.append(contentsOf: existingRecordingIDs.filter {
                !initialRecordingIDs.contains($0)
            })
            add(urls: urls)
            add(remoteSources: remoteSources)
            startIfNeeded()
            return true
        }
        resetFinishedBatchIfNeeded()
        guard currentBatchID == nil else { return false }

        do {
            try batchPersistence?.reopenBatch(batch.id)
            try batchPersistence?.addRecordingIDs(existingRecordingIDs, to: batch.id)
        } catch {
            batchError = "Could not reopen the transcription batch."
            return false
        }

        var seenRecordingIDs = Set<UUID>()
        currentBatchID = batch.id
        initialRecordingIDs = (batch.recordingIDs + existingRecordingIDs).filter {
            seenRecordingIDs.insert($0).inserted
        }
        items = batch.workItems ?? []
        batchError = nil
        add(urls: urls)
        add(remoteSources: remoteSources)
        startIfNeeded()
        finalizePersistentBatchIfFinished()
        return true
    }

    func resume(batch: TranscriptionBatch) {
        resume(batch: batch, retrying: Set(batch.retryableWorkItems.map(\.id)))
    }

    func resume(batch: TranscriptionBatch, retrying itemIDs: Set<UUID>) {
        guard canResume(batch: batch), let persistedItems = batch.workItems else {
            return
        }
        let retryableIDs = Set(batch.retryableWorkItems.map(\.id))
        let selectedIDs = itemIDs.intersection(retryableIDs)
        guard !selectedIDs.isEmpty else { return }
        do {
            try batchPersistence?.reopenBatch(batch.id)
        } catch {
            batchError = "Could not reopen the transcription batch."
            return
        }
        currentBatchID = batch.id
        initialRecordingIDs = batch.recordingIDs
        items = persistedItems.map { item in
            var item = item
            if !item.status.isTerminal || item.status == .authorizationPaused {
                item.status = .failed
            }
            return item
        }
        retry(ids: selectedIDs)
    }

    func canResume(batch: TranscriptionBatch) -> Bool {
        !isProcessing
            && (currentBatchID == nil || currentBatchID == batch.id)
            && !(batch.workItems?.isEmpty ?? true)
    }

    func add(urls: [URL]) {
        if batchPersistence != nil, currentBatchID == nil {
            beginBatch(urls: urls)
            return
        }
        let existingURLs = Set(items.map(\.sourceURL.standardizedFileURL))
        var addedURLs = Set<URL>()
        let initialItemCount = items.count

        for url in urls {
            let standardizedURL = url.standardizedFileURL
            guard !existingURLs.contains(standardizedURL),
                  addedURLs.insert(standardizedURL).inserted
            else { continue }

            var item = BatchTranscriptionItem(sourceURL: standardizedURL)
            if let duplicate = recordingStore.completedDuplicate(
                sourceIdentity: item.sourceIdentity
            ) {
                item.status = .duplicate
                item.durationSeconds = duplicate.durationSeconds
                item.transcriptionText = duplicate.transcriptionText
                item.recordingID = duplicate.recordingID
                persistRecordingID(duplicate.recordingID)
            }
            items.append(item)
        }

        if items.count > initialItemCount {
            persistWorkItems()
            wakeScheduler()
        }
    }

    func add(remoteSources: [YouTubeRemoteMediaSource]) {
        if batchPersistence != nil, currentBatchID == nil {
            beginBatch(remoteSources: remoteSources)
            return
        }
        let existingIDs = Set(items.compactMap { $0.remoteSource?.mediaID })
        var addedIDs = Set<String>()
        let initialItemCount = items.count

        for source in remoteSources {
            guard !existingIDs.contains(source.mediaID),
                  addedIDs.insert(source.mediaID).inserted
            else { continue }

            var item = BatchTranscriptionItem(remoteSource: source)
            if let duplicate = recordingStore.completedDuplicate(
                remoteProvider: YouTubeRemoteMediaSource.provider,
                mediaID: source.mediaID
            ), canReuse(duplicate: duplicate) {
                apply(duplicate: duplicate, to: &item)
                persistRecordingID(duplicate.recordingID)
            }
            items.append(item)
        }

        if items.count > initialItemCount {
            persistWorkItems()
            wakeScheduler()
        }
    }

    private func resetFinishedBatchIfNeeded() {
        if !isProcessing, items.allSatisfy(\.status.isTerminal) {
            items.removeAll()
            activeSettingsSnapshot = nil
            hasPlayedCompletionSound = false
            currentBatchID = nil
            initialRecordingIDs = []
        }
    }

    private func createPersistentBatch(
        name: String,
        description: String,
        existingRecordingIDs: [UUID]
    ) -> Bool {
        initialRecordingIDs = existingRecordingIDs
        guard let batchPersistence else { return true }
        do {
            let batchID = try batchPersistence.createBatch(
                name: name,
                description: description,
                recordingIDs: existingRecordingIDs
            )
            currentBatchID = batchID
            lastCreatedBatchID = batchID
            return true
        } catch {
            batchError = "Could not create the transcription batch."
            return false
        }
    }

    private func persistRecordingID(_ recordingID: UUID) {
        guard let batchPersistence, let currentBatchID else { return }
        do {
            try batchPersistence.addRecordingIDs([recordingID], to: currentBatchID)
            try batchPersistence.replaceWorkItems(items, in: currentBatchID)
        } catch {
            batchError = "Could not save the transcription batch."
        }
    }

    private func finalizePersistentBatchIfFinished() {
        guard !isProcessing,
              items.allSatisfy(\.status.isTerminal),
              let batchPersistence,
              let currentBatchID
        else { return }
        do {
            try batchPersistence.replaceWorkItems(items, in: currentBatchID)
            try batchPersistence.replaceRecordingIDs(
                initialRecordingIDs + items.compactMap(\.recordingID),
                in: currentBatchID
            )
            try batchPersistence.closeBatch(currentBatchID)
            self.currentBatchID = nil
            initialRecordingIDs = []
        } catch {
            batchError = "Could not finish saving the transcription batch."
        }
    }

    func startIfNeeded() {
        guard processingTask == nil,
              items.contains(where: { $0.status == .queued })
        else { return }

        let snapshot = activeSettingsSnapshot ?? settingsSnapshot()
        if items.contains(where: { $0.status == .queued && $0.remoteSource != nil }) {
            guard remoteExtractor != nil else {
                batchError = RemoteMediaExtractorError.runtimeUnavailable.localizedDescription
                return
            }
            guard chromeProfile() != nil else {
                batchError = "Select a browser session to transcribe YouTube URLs."
                return
            }
        }
        if let error = transcriber.preflightError(for: snapshot) {
            batchError = error
            return
        }

        activeSettingsSnapshot = snapshot
        batchError = nil
        isProcessing = true
        processingTask = Task { [weak self] in
            await self?.processQueuedItems(settings: snapshot)
        }
    }

    func retry(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        for index in items.indices where ids.contains(items[index].id) {
            guard items[index].status == .failed
                || items[index].status == .partialResult
                || items[index].status == .cancelled
            else { continue }
            let isCaptionOnlyRetry = items[index].status == .partialResult
                && items[index].transcriptionText != nil
                && items[index].captionErrorMessage != nil
            items[index].status = .queued
            items[index].errorMessage = nil
            if !isCaptionOnlyRetry {
                items[index].transcriptionText = nil
            } else {
                items[index].remoteArtifactWork = .captionsOnly
            }
            items[index].progressFraction = nil
            items[index].downloadedBytes = nil
            items[index].totalDownloadBytes = nil
            items[index].startedAt = nil
            items[index].finishedAt = nil
        }
        startIfNeeded()
    }

    func retryFailed() {
        retry(ids: Set(items.filter {
            $0.status == .failed || $0.status == .partialResult
        }.map(\.id)))
    }

    func retryAuthorization() {
        for index in items.indices where items[index].status == .authorizationPaused {
            items[index].status = .queued
            items[index].errorMessage = nil
            items[index].finishedAt = nil
        }
        batchError = nil
        startIfNeeded()
    }

    func cancelAll() {
        for index in items.indices where !items[index].status.isTerminal {
            items[index].status = .cancelled
            items[index].finishedAt = Date()
        }
        processingTask?.cancel()
        wakeScheduler()
    }

    func clearFinished() {
        guard !isProcessing else { return }
        items.removeAll(where: { $0.status.isTerminal })
        batchError = nil
        if items.isEmpty {
            activeSettingsSnapshot = nil
            hasPlayedCompletionSound = false
        }
    }

    private func processQueuedItems(settings: FileTranscriptionSettingsSnapshot) async {
        let activityToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "Transcribing imported media batch"
        )
        defer {
            ProcessInfo.processInfo.endActivity(activityToken)
            processingTask = nil
            activeItemIDs.removeAll()
            isProcessing = false
            let finishedBatch = !items.isEmpty && items.allSatisfy(\.status.isTerminal)
            if !Task.isCancelled, finishedBatch, !hasPlayedCompletionSound {
                hasPlayedCompletionSound = true
                playCompletionSound()
            }
            if !Task.isCancelled, items.contains(where: { $0.status == .queued }) {
                startIfNeeded()
            }
            finalizePersistentBatchIfFinished()
        }
        guard await preflightRemoteAuthorization() else { return }

        let hasRemoteWork = items.contains(where: {
            $0.remoteSource != nil && ($0.status == .queued || activeItemIDs.contains($0.id))
        })
        let concurrencyLimit = settings.provider == .cloud
            ? Self.cloudConcurrencyLimit
            : (hasRemoteWork ? 3 : 1)
        await withTaskGroup(of: Void.self) { group in
            while !Task.isCancelled {
                if items.contains(where: {
                    $0.status == .queued && $0.remoteSource != nil && $0.remoteMetadata == nil
                }) {
                    guard await preflightRemoteAuthorization() else { break }
                }

                while activeItemIDs.count < concurrencyLimit,
                      let itemID = nextQueuedItemID()
                {
                    activeItemIDs.insert(itemID)
                    group.addTask { [weak self] in
                        await self?.process(itemID: itemID, settings: settings)
                        await self?.didFinishProcessing(itemID)
                    }
                }

                guard !activeItemIDs.isEmpty else { break }
                await waitForSchedulerEvent()
            }

            group.cancelAll()
        }
    }

    private func preflightRemoteAuthorization() async -> Bool {
        let candidates = items.compactMap { item -> (UUID, YouTubeRemoteMediaSource)? in
            guard item.status == .queued,
                  item.remoteMetadata == nil,
                  let source = item.remoteSource
            else { return nil }
            return (item.id, source)
        }
        guard !candidates.isEmpty,
              let remoteExtractor,
              let profile = chromeProfile()
        else { return true }

        for (itemID, _) in candidates {
            update(itemID) { $0.status = .checkingLink }
        }

        var authorizationRequired = false
        await withTaskGroup(of: RemotePreflightOutcome.self) { group in
            for (itemID, source) in candidates {
                group.addTask { [remoteMetadataPermits] in
                    do {
                        try await remoteMetadataPermits.acquire()
                    } catch {
                        return .failed(itemID, error.localizedDescription)
                    }
                    do {
                        try Task.checkCancellation()
                        let metadata = try await remoteExtractor.metadata(
                            for: source,
                            session: profile
                        )
                        await remoteMetadataPermits.release()
                        return .metadata(itemID, metadata)
                    } catch RemoteMediaExtractorError.authorizationRequired {
                        await remoteMetadataPermits.release()
                        return .authorizationRequired
                    } catch {
                        await remoteMetadataPermits.release()
                        return .failed(itemID, error.localizedDescription)
                    }
                }
            }

            for await outcome in group {
                guard !Task.isCancelled else { continue }
                switch outcome {
                case let .metadata(itemID, metadata):
                    do {
                        try ImportedMediaAudioPreparer.validate(
                            durationSeconds: metadata.durationSeconds
                        )
                        update(itemID) {
                            $0.remoteMetadata = metadata
                            $0.durationSeconds = metadata.durationSeconds
                            $0.status = .queued
                        }
                    } catch {
                        update(itemID) {
                            $0.status = .failed
                            $0.errorMessage = error.localizedDescription
                            $0.finishedAt = Date()
                        }
                    }
                case .authorizationRequired:
                    authorizationRequired = true
                case let .failed(itemID, message):
                    update(itemID) {
                        $0.status = .failed
                        $0.errorMessage = message
                        $0.finishedAt = Date()
                    }
                }
            }
        }

        guard !Task.isCancelled else { return false }
        if authorizationRequired {
            pauseForAuthorization()
            return false
        }
        return true
    }

    private func didFinishProcessing(_ itemID: UUID) {
        activeItemIDs.remove(itemID)
        wakeScheduler()
    }

    private func waitForSchedulerEvent() async {
        await withCheckedContinuation { continuation in
            schedulerContinuation = continuation
        }
    }

    private func wakeScheduler() {
        let continuation = schedulerContinuation
        schedulerContinuation = nil
        continuation?.resume()
    }

    private func nextQueuedItemID() -> UUID? {
        items.first(where: {
            $0.status == .queued && !activeItemIDs.contains($0.id)
        })?.id
    }

    private func process(
        itemID: UUID,
        settings: FileTranscriptionSettingsSnapshot
    ) async {
        guard let item = items.first(where: { $0.id == itemID }) else { return }
        if item.remoteSource != nil {
            await processRemote(itemID: itemID, settings: settings)
        } else {
            await processLocal(itemID: itemID, settings: settings)
        }
    }

    private func processRemote(
        itemID: UUID,
        settings: FileTranscriptionSettingsSnapshot
    ) async {
        guard let initialIndex = index(of: itemID),
              let source = items[initialIndex].remoteSource,
              let remoteExtractor,
              let profile = chromeProfile()
        else { return }

        var recordingID = items[initialIndex].recordingID
        var downloadedAudio: RemoteDownloadedAudio?
        var temporaryAudio: ImportedMediaAudioPreparer.PreparedAudio?
        var selectedAudioURL: URL?
        var captionAttemptFailed = false

        defer {
            if recordingID != nil {
                downloadedAudio?.removeTemporaryFiles()
                update(itemID) { $0.downloadedAudioURL = nil }
                persistWorkItems()
            }
            temporaryAudio?.removeTemporaryFile()
            if let selectedAudioURL { try? FileManager.default.removeItem(at: selectedAudioURL) }
        }

        do {
            try Task.checkCancellation()
            markStarted(itemID)

            var metadata = items[initialIndex].remoteMetadata
            let storedAudioURL = recordingID.flatMap {
                recordingStore.audioFileURL(recordingID: $0)
            }

            if items[initialIndex].remoteArtifactWork == .captionsOnly,
               let metadata
            {
                update(itemID) { $0.status = .retrievingCaptions }
                do {
                    let artifact = try await withRemoteAcquisitionPermit {
                        try await remoteExtractor.retrieveCaption(
                            for: source,
                            metadata: metadata,
                            session: profile
                        )
                    }
                    let artifacts = artifact.map { [$0] } ?? []
                    if let recordingID {
                        recordingStore.updateSourceCaptionArtifacts(
                            recordingID: recordingID,
                            artifacts: artifacts
                        )
                    }
                    update(itemID) {
                        $0.sourceCaptionArtifacts = artifacts
                        $0.captionErrorMessage = nil
                        $0.errorMessage = nil
                        $0.progressFraction = 1
                        $0.status = .completed
                        $0.remoteArtifactWork = .all
                        $0.finishedAt = Date()
                    }
                    return
                } catch RemoteMediaExtractorError.authorizationRequired {
                    throw RemoteMediaExtractorError.authorizationRequired
                } catch {
                    update(itemID) {
                        $0.status = .partialResult
                        $0.captionErrorMessage = "Source captions could not be retrieved."
                        $0.errorMessage = "Source captions could not be retrieved."
                        $0.finishedAt = Date()
                    }
                    return
                }
            }

            if storedAudioURL == nil {
                if metadata == nil {
                    update(itemID) { $0.status = .checkingLink }
                    metadata = try await remoteExtractor.metadata(for: source, session: profile)
                }
                guard let metadata else {
                    throw RemoteMediaExtractorError.malformedMetadata
                }
                try ImportedMediaAudioPreparer.validate(durationSeconds: metadata.durationSeconds)
                update(itemID) {
                    $0.remoteMetadata = metadata
                    $0.durationSeconds = metadata.durationSeconds
                    $0.status = .checkingDuplicate
                }

                if let duplicate = recordingStore.completedDuplicate(
                    remoteMetadata: metadata.source,
                    durationSeconds: metadata.durationSeconds
                ), canReuse(duplicate: duplicate) {
                    update(itemID) { apply(duplicate: duplicate, to: &$0) }
                    persistRecordingID(duplicate.recordingID)
                    return
                }

                if let checkpointURL = items[initialIndex].downloadedAudioURL,
                   FileManager.default.fileExists(atPath: checkpointURL.path)
                {
                    downloadedAudio = RemoteDownloadedAudio(
                        fileURL: checkpointURL,
                        temporaryDirectory: checkpointURL.deletingLastPathComponent()
                    )
                } else {
                    let acquisition = try await withRemoteAcquisitionPermit {
                        if items[initialIndex].remoteArtifactWork != .transcriptOnly,
                           items[initialIndex].sourceCaptionArtifacts.isEmpty
                        {
                            update(itemID) { $0.status = .retrievingCaptions }
                            do {
                                if let caption = try await remoteExtractor.retrieveCaption(
                                    for: source,
                                    metadata: metadata,
                                    session: profile
                                ) {
                                    update(itemID) { $0.sourceCaptionArtifacts = [caption] }
                                }
                            } catch RemoteMediaExtractorError.authorizationRequired {
                                throw RemoteMediaExtractorError.authorizationRequired
                            } catch {
                                captionAttemptFailed = true
                                update(itemID) {
                                    $0.captionErrorMessage = "Source captions could not be retrieved."
                                }
                            }
                        }

                        update(itemID) {
                            $0.status = .downloading
                            $0.progressFraction = nil
                        }
                        return try await remoteExtractor.downloadAudio(
                            for: source,
                            metadata: metadata,
                            session: profile
                        ) { [weak self] progress in
                            Task { @MainActor in
                                self?.update(itemID) {
                                    $0.downloadedBytes = progress.downloadedBytes
                                    $0.totalDownloadBytes = progress.totalBytes
                                    $0.progressFraction = progress.fractionCompleted
                                }
                            }
                        }
                    }
                    downloadedAudio = acquisition
                    update(itemID) {
                        $0.downloadedAudioURL = acquisition.fileURL
                        $0.status = .preparing
                    }
                }
                try Task.checkCancellation()

                guard let downloadedAudio else {
                    throw RemoteMediaExtractorError.acquisitionFailed
                }
                update(itemID) {
                    $0.status = .preparing
                    $0.progressFraction = nil
                }
                let prepared = try await preparer.prepare(sourceURL: downloadedAudio.fileURL)
                temporaryAudio = prepared
                try Task.checkCancellation()

                recordingID = recordingStore.savePreparedAudio(
                    at: prepared.fileURL,
                    durationSeconds: prepared.durationSeconds,
                    remoteMetadata: metadata.source,
                    sourceCaptionArtifacts: item(withID: itemID)?.sourceCaptionArtifacts ?? []
                )
                if let recordingID {
                    update(itemID) { $0.recordingID = recordingID }
                    persistRecordingID(recordingID)
                    recordingStore.markProcessing(recordingID: recordingID)
                }
            } else if let recordingID {
                recordingStore.markProcessing(recordingID: recordingID)
            }

            let availableAudioURL = recordingID.flatMap { recordingStore.audioFileURL(recordingID: $0) }
                ?? temporaryAudio?.fileURL
                ?? storedAudioURL
            guard let originalAudioURL = availableAudioURL else { throw CocoaError(.fileNoSuchFile) }
            let audioURL = try await prepareSelectedAudio(fileURL: originalAudioURL, recordingID: recordingID, itemID: itemID)
            if audioURL != originalAudioURL { selectedAudioURL = audioURL }

            update(itemID) {
                $0.status = settings.provider == .cloud ? .uploading : .processing
                $0.progressFraction = nil
            }
            let transcript = try await transcribeWithPermit(
                audioFileURL: audioURL,
                settings: settings,
                source: item(withID: itemID)?.displayName ?? audioURL.lastPathComponent,
                sourceDurationSeconds: item(withID: itemID)?.durationSeconds,
                itemID: itemID
            ) { [weak self] progressUpdate in
                Task { @MainActor in
                    self?.apply(progressUpdate: progressUpdate, to: itemID)
                }
            }
            try Task.checkCancellation()

            if let recordingID {
                recordingStore.markCompleted(
                    recordingID: recordingID,
                    transcript: transcript,
                    provenance: GeneratedTranscriptProvenance(provider: settings.provider.rawValue)
                )
            }
            update(itemID) {
                $0.status = captionAttemptFailed ? .partialResult : .completed
                $0.progressFraction = 1
                $0.finishedAt = Date()
                $0.transcriptionText = transcript.text
                $0.errorMessage = captionAttemptFailed ? $0.captionErrorMessage : nil
            }
        } catch RemoteMediaExtractorError.authorizationRequired {
            pauseForAuthorization()
        } catch is CancellationError {
            if item(withID: itemID)?.status == .authorizationPaused { return }
            if let recordingID {
                recordingStore.markUnprocessed(recordingID: recordingID)
            }
            update(itemID) {
                $0.status = .cancelled
                $0.finishedAt = Date()
                $0.errorMessage = nil
            }
        } catch {
            let message = error.localizedDescription
            if let recordingID {
                recordingStore.markFailed(recordingID: recordingID, error: message)
            }
            update(itemID) {
                $0.status = $0.sourceCaptionArtifacts.isEmpty ? .failed : .partialResult
                $0.finishedAt = Date()
                $0.errorMessage = message
            }
        }
    }

    private func processLocal(
        itemID: UUID,
        settings: FileTranscriptionSettingsSnapshot
    ) async {
        guard let initialIndex = index(of: itemID) else { return }

        var recordingID = items[initialIndex].recordingID
        var audioURL: URL?
        var temporaryAudio: ImportedMediaAudioPreparer.PreparedAudio?
        var selectedAudioURL: URL?
        defer {
            temporaryAudio?.removeTemporaryFile()
            if let selectedAudioURL { try? FileManager.default.removeItem(at: selectedAudioURL) }
        }

        do {
            try Task.checkCancellation()
            markStarted(itemID)

            let storedAudioURL = recordingID.flatMap {
                recordingStore.audioFileURL(recordingID: $0)
            }
            if let recordingID, let storedAudioURL {
                audioURL = storedAudioURL
                recordingStore.markProcessing(recordingID: recordingID)
            } else {
                update(itemID) {
                    $0.status = .preparing
                }

                let preparedAudio = try await preparer.prepare(
                    sourceURL: items[initialIndex].sourceURL
                )
                temporaryAudio = preparedAudio
                try Task.checkCancellation()

                audioURL = preparedAudio.fileURL
                update(itemID) { $0.durationSeconds = preparedAudio.durationSeconds }

                recordingID = recordingStore.savePreparedAudio(
                    at: preparedAudio.fileURL,
                    durationSeconds: preparedAudio.durationSeconds,
                    sourceIdentity: items[initialIndex].sourceIdentity
                )
                if let recordingID {
                    update(itemID) { $0.recordingID = recordingID }
                    persistRecordingID(recordingID)
                    recordingStore.markProcessing(recordingID: recordingID)
                }
            }

            guard let originalAudioURL = audioURL else {
                throw CocoaError(.fileNoSuchFile)
            }
            let audioURL = try await prepareSelectedAudio(fileURL: originalAudioURL, recordingID: recordingID, itemID: itemID)
            if audioURL != originalAudioURL { selectedAudioURL = audioURL }

            update(itemID) { $0.status = settings.provider == .cloud ? .uploading : .processing }
            let transcript = try await transcribeWithPermit(
                audioFileURL: audioURL,
                settings: settings,
                source: item(withID: itemID)?.displayName ?? audioURL.lastPathComponent,
                sourceDurationSeconds: item(withID: itemID)?.durationSeconds,
                itemID: itemID
            ) { [weak self] progressUpdate in
                Task { @MainActor in
                    self?.apply(progressUpdate: progressUpdate, to: itemID)
                }
            }
            try Task.checkCancellation()

            if let recordingID {
                recordingStore.markCompleted(
                    recordingID: recordingID,
                    transcript: transcript,
                    provenance: GeneratedTranscriptProvenance(provider: settings.provider.rawValue)
                )
            }
            update(itemID) {
                $0.status = .completed
                $0.progressFraction = 1
                $0.finishedAt = Date()
                $0.transcriptionText = transcript.text
                $0.errorMessage = nil
            }
        } catch is CancellationError {
            if let recordingID {
                recordingStore.markUnprocessed(recordingID: recordingID)
            }
            update(itemID) {
                $0.status = .cancelled
                $0.finishedAt = Date()
                $0.errorMessage = nil
            }
        } catch {
            let message = error.localizedDescription
            if let recordingID {
                recordingStore.markFailed(recordingID: recordingID, error: message)
            }
            update(itemID) {
                $0.status = .failed
                $0.finishedAt = Date()
                $0.errorMessage = message
            }
        }

    }

    private func pauseForAuthorization() {
        batchError = RemoteMediaExtractorError.authorizationRequired.localizedDescription
        for index in items.indices where items[index].remoteSource != nil
            && !items[index].status.isTerminal
        {
            items[index].status = .authorizationPaused
            items[index].errorMessage = nil
            items[index].finishedAt = nil
        }
        persistWorkItems()
        processingTask?.cancel()
        wakeScheduler()
    }

    private func prepareSelectedAudio(fileURL: URL, recordingID: UUID?, itemID: UUID) async throws -> URL {
        guard let recordingID, let recording = recordingStore.storedRecording(recordingID: recordingID)
        else { return fileURL }
        update(itemID) { $0.durationSeconds = recording.effectiveDurationSeconds }
        return try await AudioTrimService.prepareAudio(fileURL: fileURL, range: recording.trimRange)
    }

    private func transcribeWithPermit(
        audioFileURL: URL,
        settings: FileTranscriptionSettingsSnapshot,
        source: String,
        sourceDurationSeconds: TimeInterval?,
        itemID: UUID,
        onUpdate: @escaping (JobProgressUpdate) -> Void
    ) async throws -> GeneratedTranscript {
        let permits = settings.provider == .cloud
            ? cloudTranscriptionPermits
            : localTranscriptionPermits
        try await permits.acquire()
        do {
            try Task.checkCancellation()
            let currentRange = item(withID: itemID)?.recordingID.flatMap {
                recordingStore.storedRecording(recordingID: $0)?.trimRange
            }
            if item(withID: itemID)?.cloudJobTrimRange != currentRange {
                update(itemID) {
                    $0.cloudJobID = nil
                    $0.cloudJobTrimRange = nil
                }
                persistWorkItems()
            }
            let result = try await transcriber.transcribe(
                audioFileURL: audioFileURL,
                settings: settings,
                source: source,
                sourceDurationSeconds: sourceDurationSeconds,
                resumeJobID: item(withID: itemID)?.cloudJobID,
                onJobSubmitted: { [weak self] jobID in
                    self?.update(itemID) {
                        $0.cloudJobID = jobID
                        $0.cloudJobTrimRange = currentRange
                    }
                    self?.persistWorkItems()
                },
                onUpdate: onUpdate
            )
            await permits.release()
            return result
        } catch {
            await permits.release()
            throw error
        }
    }

    private func withRemoteAcquisitionPermit<T>(
        _ operation: () async throws -> T
    ) async throws -> T {
        try await remoteAcquisitionPermits.acquire()
        do {
            try Task.checkCancellation()
            let result = try await operation()
            await remoteAcquisitionPermits.release()
            return result
        } catch {
            await remoteAcquisitionPermits.release()
            throw error
        }
    }

    private func apply(
        duplicate: BatchTranscriptionDuplicate,
        to item: inout BatchTranscriptionItem
    ) {
        item.durationSeconds = duplicate.durationSeconds
        item.transcriptionText = duplicate.transcriptionText
        item.sourceCaptionArtifacts = duplicate.sourceCaptionArtifacts
        item.recordingID = duplicate.recordingID
        let hasTranscript = !(duplicate.transcriptionText?.isEmpty ?? true)
        let hasCaptions = !duplicate.sourceCaptionArtifacts.isEmpty
        if hasTranscript, hasCaptions {
            item.status = .duplicate
            item.remoteArtifactWork = .all
            item.progressFraction = 1
            item.finishedAt = Date()
        } else {
            item.status = .queued
            item.remoteArtifactWork = hasTranscript ? .captionsOnly : .transcriptOnly
            item.progressFraction = nil
            item.finishedAt = nil
        }
    }

    private func canReuse(duplicate: BatchTranscriptionDuplicate) -> Bool {
        if !(duplicate.transcriptionText?.isEmpty ?? true) {
            return true
        }
        return !duplicate.sourceCaptionArtifacts.isEmpty
            && recordingStore.audioFileURL(recordingID: duplicate.recordingID) != nil
    }

    private func item(withID itemID: UUID) -> BatchTranscriptionItem? {
        items.first(where: { $0.id == itemID })
    }

    private func markStarted(_ itemID: UUID) {
        update(itemID) {
            $0.startedAt = Date()
            $0.finishedAt = nil
            $0.progressFraction = nil
            $0.errorMessage = nil
        }
    }

    private func apply(progressUpdate: JobProgressUpdate, to itemID: UUID) {
        update(itemID) { item in
            guard !item.status.isTerminal else { return }
            switch progressUpdate.status {
            case .queued:
                item.status = .queued
            case .uploading:
                item.status = .uploading
            case .processing:
                item.status = .processing
            case .finalizing:
                item.status = .finalizing
            case .completed:
                break
            case .error:
                item.status = .failed
            }
            item.progressFraction = progressUpdate.fractionCompleted
        }
    }

    private func index(of itemID: UUID) -> Int? {
        items.firstIndex(where: { $0.id == itemID })
    }

    private func update(
        _ itemID: UUID,
        _ mutation: (inout BatchTranscriptionItem) -> Void
    ) {
        guard let index = index(of: itemID) else { return }
        let oldStatus = items[index].status
        mutation(&items[index])
        if items[index].status != oldStatus {
            persistWorkItems()
        }
    }

    private func persistWorkItems() {
        guard let batchPersistence, let currentBatchID else { return }
        do {
            try batchPersistence.replaceWorkItems(items, in: currentBatchID)
        } catch {
            batchError = "Could not save the transcription batch."
        }
    }
}

private final class LiveFileTranscriptionBatchTranscriber: FileTranscriptionBatchTranscribing {
    func preflightError(for settings: FileTranscriptionSettingsSnapshot) -> String? {
        switch settings.provider {
        case .cloud:
            return AuthService.hasStoredSession ? nil : "Log in to use Cloud transcription."
        case .local:
            guard let model = WhisperModelManager.availableModels.first(where: {
                $0.name == settings.localModelName
            }), WhisperModelManager.shared.isModelDownloaded(model)
            else {
                return "Download a local Whisper model in Settings to transcribe files and YouTube."
            }
            return nil
        }
    }

    func transcribe(
        audioFileURL: URL,
        settings: FileTranscriptionSettingsSnapshot,
        source: String,
        sourceDurationSeconds: TimeInterval?,
        resumeJobID: String?,
        onJobSubmitted: @escaping (String) -> Void,
        onUpdate: @escaping (JobProgressUpdate) -> Void
    ) async throws -> GeneratedTranscript {
        switch settings.provider {
        case .cloud:
            var config: [String: Any] = ["mode": "transcribe"]
            if !settings.languageHints.isEmpty {
                config["language_hints"] = settings.languageHints
                config["language_hints_strict"] = true
            }
            let service = AsyncTranscriptionJobService()
            if let resumeJobID {
                return try await service.resumeFileDetailed(
                    jobID: resumeJobID,
                    config: config,
                    onProgressUpdate: onUpdate
                )
            }
            return try await service.transcribeFileDetailedWithRetry(
                audioFileURL: audioFileURL,
                config: config,
                source: source,
                sourceDurationSeconds: sourceDurationSeconds,
                onSubmitted: onJobSubmitted,
                onProgressUpdate: onUpdate
            )
        case .local:
            onUpdate(JobProgressUpdate(status: .processing))
            let audioData = try await Task.detached(priority: .utility) {
                try Data(contentsOf: audioFileURL, options: .mappedIfSafe)
            }.value
            let service = WhisperTranscriptionService()
            service.modelNameOverride = settings.localModelName
            return try await service.transcribeDetailed(audioData: audioData)
        }
    }
}

@MainActor
final class LiveFileTranscriptionBatchRecordingStore: FileTranscriptionBatchRecordingStoring {
    private let storage: RecordingsLibraryStorage

    init(storage: RecordingsLibraryStorage? = nil) {
        self.storage = storage ?? .shared
    }

    func storedRecording(recordingID: UUID) -> Recording? {
        storage.recordings.first { $0.id == recordingID }
    }

    func completedDuplicate(sourceIdentity: ImportedMediaIdentity) -> BatchTranscriptionDuplicate? {
        guard let sourceFileSizeBytes = sourceIdentity.fileSizeBytes else { return nil }
        guard let recording = storage.recordings.first(where: {
            $0.type == .fileTranscription
                && representsFullSource($0)
                && ($0.status == .transcribed || $0.status == .translated)
                && $0.sourceFileName?.localizedCaseInsensitiveCompare(sourceIdentity.fileName) == .orderedSame
                && $0.sourceFileSizeBytes == sourceFileSizeBytes
                && !($0.transcriptionText?.isEmpty ?? true)
        }), let transcriptionText = recording.transcriptionText
        else { return nil }

        return BatchTranscriptionDuplicate(
            recordingID: recording.id,
            transcriptionText: transcriptionText,
            durationSeconds: recording.durationSeconds
        )
    }

    func completedDuplicate(
        remoteProvider: String,
        mediaID: String
    ) -> BatchTranscriptionDuplicate? {
        guard let recording = storage.recordings.first(where: {
            representsFullSource($0)
                && $0.remoteSource?.provider == remoteProvider
                && $0.remoteSource?.mediaID == mediaID
                && hasReusableArtifact($0)
        }) else { return nil }
        return duplicate(from: recording)
    }

    func completedDuplicate(
        remoteMetadata: RemoteMediaSourceMetadata,
        durationSeconds: TimeInterval
    ) -> BatchTranscriptionDuplicate? {
        guard let recording = storage.recordings.first(where: {
            representsFullSource($0) && RemoteRecordingDuplicateMatcher.matches(
                $0,
                metadata: remoteMetadata,
                durationSeconds: durationSeconds
            )
        }) else { return nil }
        if recording.remoteSource == nil {
            storage.updateRemoteArtifacts(id: recording.id, remoteSource: remoteMetadata)
        }
        return duplicate(from: recording)
    }

    func savePreparedAudio(
        at audioURL: URL,
        durationSeconds: TimeInterval,
        sourceIdentity: ImportedMediaIdentity
    ) -> UUID? {
        storage.saveRecording(
            audioURL: audioURL,
            type: .fileTranscription,
            duration: durationSeconds,
            sourceFileName: sourceIdentity.fileName,
            sourceFileSizeBytes: sourceIdentity.fileSizeBytes
        )
    }

    func savePreparedAudio(
        at audioURL: URL,
        durationSeconds: TimeInterval,
        remoteMetadata: RemoteMediaSourceMetadata,
        sourceCaptionArtifacts: [TranscriptArtifact]
    ) -> UUID? {
        storage.saveRecording(
            audioURL: audioURL,
            type: .fileTranscription,
            duration: durationSeconds,
            sourceFileName: remoteMetadata.title,
            remoteSource: remoteMetadata,
            sourceCaptionArtifacts: sourceCaptionArtifacts
        )
    }

    func audioFileURL(recordingID: UUID) -> URL? {
        guard let recording = storage.recordings.first(where: { $0.id == recordingID }) else {
            return nil
        }
        let url = storage.audioFileURL(for: recording)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func markProcessing(recordingID: UUID) {
        storage.updateRecording(id: recordingID, status: .processing, error: nil)
    }

    func markCompleted(
        recordingID: UUID,
        transcript: GeneratedTranscript,
        provenance: GeneratedTranscriptProvenance?
    ) {
        let provider = provenance?.provider ?? TranscriptionProvider.cloud.rawValue
        storage.completeTranscription(
            id: recordingID,
            status: .transcribed,
            text: transcript.text,
            segments: transcript.segments.isEmpty ? nil : transcript.segments,
            generatedTranscriptProvenance: provenance,
            kind: provider == TranscriptionProvider.local.rawValue ? .local : .cloud,
            provider: provider
        )
    }

    func markFailed(recordingID: UUID, error: String) {
        storage.updateRecording(id: recordingID, status: .failed, error: error)
    }

    func markUnprocessed(recordingID: UUID) {
        storage.updateRecording(id: recordingID, status: .unprocessed, error: nil)
    }

    func updateSourceCaptionArtifacts(recordingID: UUID, artifacts: [TranscriptArtifact]) {
        storage.updateRemoteArtifacts(id: recordingID, sourceCaptionArtifacts: artifacts)
    }

    private func representsFullSource(_ recording: Recording) -> Bool {
        recording.trimRange == nil && recording.resolvedTranscriptHistory.last?.sourceTrimRange == nil
    }

    private func hasReusableArtifact(_ recording: Recording) -> Bool {
        !(recording.transcriptionText?.isEmpty ?? true)
            || !(recording.sourceCaptionArtifacts?.isEmpty ?? true)
    }

    private func duplicate(from recording: Recording) -> BatchTranscriptionDuplicate {
        BatchTranscriptionDuplicate(
            recordingID: recording.id,
            transcriptionText: recording.transcriptionText,
            durationSeconds: recording.durationSeconds,
            sourceCaptionArtifacts: recording.sourceCaptionArtifacts ?? []
        )
    }
}
