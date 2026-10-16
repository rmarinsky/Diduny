import Foundation

enum TranscriptionBatchStatus: String, Codable {
    case processing = "Processing"
    case completed = "Completed"
    case completedWithIssues = "Completed with Issues"
}

struct TranscriptionBatch: Codable, Equatable, Identifiable {
    let id: UUID
    var name: String
    var description: String
    let createdAt: Date
    var isProcessingClosed: Bool
    var recordingIDs: [UUID]
    var workItems: [BatchTranscriptionItem]?

    init(
        id: UUID = UUID(),
        name: String,
        description: String = "",
        createdAt: Date = Date(),
        isProcessingClosed: Bool = false,
        recordingIDs: [UUID] = [],
        workItems: [BatchTranscriptionItem]? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.createdAt = createdAt
        self.isProcessingClosed = isProcessingClosed
        self.recordingIDs = recordingIDs
        self.workItems = workItems
    }

    func status(in recordings: [Recording]) -> TranscriptionBatchStatus {
        guard isProcessingClosed else { return .processing }
        if workItems?.contains(where: {
            $0.status != .completed && $0.status != .duplicate
        }) == true {
            return .completedWithIssues
        }
        let byID = Dictionary(uniqueKeysWithValues: recordings.map { ($0.id, $0) })
        return recordingIDs.allSatisfy { id in
            guard let recording = byID[id] else { return false }
            return recording.status == .transcribed || recording.status == .translated
        } ? .completed : .completedWithIssues
    }

    var retryableWorkItems: [BatchTranscriptionItem] {
        (workItems ?? []).filter { $0.status != .completed && $0.status != .duplicate }
    }

    var inspectableWorkItems: [BatchTranscriptionItem] {
        workItems ?? []
    }

    func matches(_ query: String, recordings: [Recording]) -> Bool {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return true }
        if name.localizedCaseInsensitiveContains(normalized)
            || description.localizedCaseInsensitiveContains(normalized)
        {
            return true
        }
        let memberIDs = Set(recordingIDs)
        return recordings.contains { recording in
            memberIDs.contains(recording.id)
                && [
                    recording.title,
                    recording.description,
                    recording.sourceFileName,
                    recording.remoteSource?.title,
                    recording.remoteSource?.channelName,
                    recording.remoteSource?.description,
                    recording.remoteSource?.canonicalURL.absoluteString,
                    recording.libraryDisplayName,
                    recording.transcriptionText
                ].compactMap { $0 }.contains {
                    $0.localizedCaseInsensitiveContains(normalized)
                }
                || memberIDs.contains(recording.id)
                && recording.resolvedTranscriptHistory.contains {
                    $0.text.localizedCaseInsensitiveContains(normalized)
                }
        } || workItems?.contains {
            $0.displayName.localizedCaseInsensitiveContains(normalized)
                || ($0.errorMessage?.localizedCaseInsensitiveContains(normalized) ?? false)
        } == true
    }

    func markdown(recordings: [Recording]) -> String {
        let byID = Dictionary(uniqueKeysWithValues: recordings.map { ($0.id, $0) })
        let workItemRecordingIDs = Set((workItems ?? []).compactMap(\.recordingID))
        let recordingsMarkdown = recordingIDs.filter { !workItemRecordingIDs.contains($0) }
            .compactMap { id -> String? in
                guard let recording = byID[id] else { return nil }
                return recordingMarkdown(recording)
            }
        let workItemsMarkdown = (workItems ?? []).compactMap { item -> String? in
            if let recordingID = item.recordingID, let recording = byID[recordingID] {
                return recordingMarkdown(recording)
            }
            let source = item.remoteSource == nil ? "File Transcription" : "YouTube"
            return "## \(item.displayName)\n\nType: \(source)\n\n[Transcript unavailable — \(item.errorMessage ?? "Not completed")]"
        }
        var header = "# \(name)"
        if !description.isEmpty { header += "\n\n\(description)" }
        header += "\n\nCreated: \(createdAt.formatted(.iso8601))"
        return ([header] + recordingsMarkdown + workItemsMarkdown).joined(separator: "\n\n")
    }

    private func recordingMarkdown(_ recording: Recording) -> String {
        let totalSeconds = max(0, Int(recording.durationSeconds.rounded()))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        let duration = hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
        var metadata = [
            "Type: \(recording.libraryDisplayName)",
            "Duration: \(duration)",
            "Date: \(recording.createdAt.formatted(.iso8601))"
        ]
        if let description = recording.description, !description.isEmpty {
            metadata.append("Description: \(description)")
        }
        if let sourceURL = recording.remoteSource?.canonicalURL.absoluteString {
            metadata.append("Source URL: \(sourceURL)")
        }
        let versions = recording.resolvedTranscriptHistory
        let history = versions.isEmpty
            ? "[Transcript unavailable — \(recording.status.displayName)]"
            : versions.map { version in
                var heading = switch version.kind {
                case .cloud: "Cloud"
                case .local: "Local"
                case .translation: "Translation"
                }
                if version.kind == .translation,
                   let source = version.sourceLanguageCode,
                   let target = version.targetLanguageCode
                {
                    heading += " · \(source) → \(target)"
                }
                var details = ["Processed: \(version.createdAt.formatted(.iso8601))"]
                if let provider = version.provider { details.append("Provider: \(provider)") }
                if let model = version.modelIdentifier { details.append("Model: \(model)") }
                return "### \(heading)\n\n\(details.joined(separator: "\n"))\n\n\(version.displayText)"
            }.joined(separator: "\n\n")
        return "## \(recording.displayTitle)\n\n\(metadata.joined(separator: "\n"))\n\n\(history)"
    }
}

@Observable
@MainActor
final class TranscriptionBatchStorage {
    enum StorageError: LocalizedError {
        case batchNotFound
        case membershipClosed
        case unreadableMetadata

        var errorDescription: String? {
            switch self {
            case .batchNotFound: String(localized: "Batch not found.")
            case .membershipClosed: String(localized: "Completed batch membership cannot be changed.")
            case .unreadableMetadata: String(localized: "Batch data could not be loaded, so it was left unchanged.")
            }
        }
    }

    static let shared: TranscriptionBatchStorage = {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        let bundleID = Bundle.main.bundleIdentifier ?? "Diduny"
        let baseDirectory = appSupport.appendingPathComponent(bundleID)
        do {
            return try TranscriptionBatchStorage(baseDirectory: baseDirectory)
        } catch {
            return TranscriptionBatchStorage(unavailableAt: baseDirectory, error: error)
        }
    }()

    private(set) var batches: [TranscriptionBatch]
    private(set) var loadErrorMessage: String?
    private let metadataURL: URL

    init(baseDirectory: URL) throws {
        try FileManager.default.createDirectory(
            at: baseDirectory,
            withIntermediateDirectories: true
        )
        metadataURL = baseDirectory.appendingPathComponent("transcription_batches.json")
        loadErrorMessage = nil
        guard FileManager.default.fileExists(atPath: metadataURL.path) else {
            batches = []
            return
        }
        let data: Data
        do {
            data = try Data(contentsOf: metadataURL)
        } catch {
            batches = []
            loadErrorMessage = "Diduny couldn't read batches. The original data remains at \(metadataURL.path)."
            return
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            batches = try decoder.decode([TranscriptionBatch].self, from: data)
        } catch {
            batches = []
            loadErrorMessage = "Diduny couldn't load batches. The original data remains at \(metadataURL.path)."
            return
        }
        batches.sort { $0.createdAt > $1.createdAt }
    }

    private init(unavailableAt baseDirectory: URL, error: Error) {
        metadataURL = baseDirectory.appendingPathComponent("transcription_batches.json")
        batches = []
        loadErrorMessage = "Diduny couldn't access batch storage: \(error.localizedDescription)"
    }

    @discardableResult
    func create(
        name: String,
        description: String = "",
        recordingIDs: [UUID],
        createdAt: Date = Date()
    ) throws -> TranscriptionBatch {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let batch = TranscriptionBatch(
            name: trimmedName.isEmpty ? Self.defaultName(for: createdAt) : trimmedName,
            description: description.trimmingCharacters(in: .whitespacesAndNewlines),
            createdAt: createdAt,
            recordingIDs: unique(recordingIDs)
        )
        try mutateAndSave {
            batches.insert(batch, at: 0)
        }
        return batch
    }

    func update(batchID: UUID, name: String, description: String) throws {
        guard let index = batches.firstIndex(where: { $0.id == batchID }) else {
            throw StorageError.batchNotFound
        }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        try mutateAndSave {
            batches[index].name = trimmedName.isEmpty
                ? Self.defaultName(for: batches[index].createdAt)
                : trimmedName
            batches[index].description = description.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    func addRecordingIDs(_ recordingIDs: [UUID], to batchID: UUID) throws {
        guard let index = batches.firstIndex(where: { $0.id == batchID }) else {
            throw StorageError.batchNotFound
        }
        guard !batches[index].isProcessingClosed else {
            throw StorageError.membershipClosed
        }
        let ids = unique(batches[index].recordingIDs + recordingIDs)
        try mutateAndSave {
            batches[index].recordingIDs = ids
        }
    }

    func replaceRecordingIDs(_ recordingIDs: [UUID], in batchID: UUID) throws {
        guard let index = batches.firstIndex(where: { $0.id == batchID }) else {
            throw StorageError.batchNotFound
        }
        let ids = unique(recordingIDs)
        try mutateAndSave {
            batches[index].recordingIDs = ids
        }
    }

    func replaceWorkItems(_ items: [BatchTranscriptionItem], in batchID: UUID) throws {
        guard let index = batches.firstIndex(where: { $0.id == batchID }) else {
            throw StorageError.batchNotFound
        }
        try mutateAndSave {
            batches[index].workItems = items
        }
    }

    func reopen(batchID: UUID) throws {
        guard let index = batches.firstIndex(where: { $0.id == batchID }) else {
            throw StorageError.batchNotFound
        }
        try mutateAndSave {
            batches[index].isProcessingClosed = false
        }
    }

    func close(batchID: UUID) throws {
        guard let index = batches.firstIndex(where: { $0.id == batchID }) else {
            throw StorageError.batchNotFound
        }
        try mutateAndSave {
            batches[index].isProcessingClosed = true
        }
    }

    @discardableResult
    func removeRecordingReferences(
        _ ids: Set<UUID>,
        allowDuringRecordingRecovery: Bool = false,
        deferDownloadedArtifactRemoval: Bool = false
    ) throws -> [BatchTranscriptionItem] {
        guard !ids.isEmpty else { return [] }
        let removedItems = batches.flatMap { batch in
            (batch.workItems ?? []).filter { $0.recordingID.map(ids.contains) == true }
        }
        try removedItems.forEach(validateDownloadedArtifact)
        try mutateAndSave(allowDuringRecordingRecovery: allowDuringRecordingRecovery) {
            for index in batches.indices {
                batches[index].recordingIDs.removeAll(where: ids.contains)
                batches[index].workItems?.removeAll { item in
                    item.recordingID.map(ids.contains) == true
                }
            }
        }
        if !deferDownloadedArtifactRemoval {
            removeDownloadedArtifacts(removedItems)
        }
        return removedItems
    }

    func restoreSnapshot(_ snapshot: [TranscriptionBatch]) throws {
        try mutateAndSave(allowDuringRecordingRecovery: true) {
            batches = snapshot
        }
    }

    @discardableResult
    func delete(
        batchID: UUID,
        allowDuringRecordingRecovery: Bool = false,
        deferDownloadedArtifactRemoval: Bool = false
    ) throws -> (recordingIDs: Set<UUID>, removedItems: [BatchTranscriptionItem]) {
        guard let batch = batches.first(where: { $0.id == batchID }) else {
            throw StorageError.batchNotFound
        }
        let affected = Set(batch.recordingIDs)
        let removedItems = batches.flatMap { candidate in
            (candidate.workItems ?? []).filter { item in
                candidate.id == batchID || item.recordingID.map(affected.contains) == true
            }
        }
        try removedItems.forEach(validateDownloadedArtifact)
        try mutateAndSave(allowDuringRecordingRecovery: allowDuringRecordingRecovery) {
            batches.removeAll { $0.id == batchID }
            for index in batches.indices {
                batches[index].recordingIDs.removeAll(where: affected.contains)
                batches[index].workItems?.removeAll { item in
                    item.recordingID.map(affected.contains) == true
                }
            }
        }
        if !deferDownloadedArtifactRemoval {
            removeDownloadedArtifacts(removedItems)
        }
        return (affected, removedItems)
    }

    @discardableResult
    func removeDownloadedArtifacts(_ items: [BatchTranscriptionItem]) -> Bool {
        removeDownloadedArtifacts(at: items.compactMap {
            $0.downloadedAudioURL?.standardizedFileURL.path
        })
    }

    @discardableResult
    func removeDownloadedArtifacts(at paths: [String]) -> Bool {
        guard paths.allSatisfy(Self.isValidDownloadedArtifactPath) else { return false }
        for path in paths {
            do {
                try removeDownloadedArtifact(at: path)
            } catch {
                Log.app.error("Failed to clean downloaded batch artifact: \(error.localizedDescription)")
            }
        }
        return paths.allSatisfy { !FileManager.default.fileExists(atPath: $0) }
    }

    private func validateDownloadedArtifact(_ item: BatchTranscriptionItem) throws {
        guard let path = item.downloadedAudioURL?.standardizedFileURL.path else { return }
        guard Self.isValidDownloadedArtifactPath(path) else {
            throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: path])
        }
    }

    nonisolated static func isValidDownloadedArtifactPath(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let temporaryRoot = FileManager.default.temporaryDirectory.standardizedFileURL.path + "/"
        return url.path.hasPrefix(temporaryRoot)
    }

    private func removeDownloadedArtifact(at path: String) throws {
        guard Self.isValidDownloadedArtifactPath(path) else {
            throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: path])
        }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let fileManager = FileManager.default
        let temporaryRoot = fileManager.temporaryDirectory.standardizedFileURL.path + "/"
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }

        let parent = url.deletingLastPathComponent()
        guard parent.path.hasPrefix(temporaryRoot),
              (try? fileManager.contentsOfDirectory(atPath: parent.path).isEmpty) == true
        else { return }
        try? fileManager.removeItem(at: parent)
    }

    private func save() throws {
        guard loadErrorMessage == nil else { throw StorageError.unreadableMetadata }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(batches).write(to: metadataURL, options: .atomic)
    }

    private func mutateAndSave(
        allowDuringRecordingRecovery: Bool = false,
        _ mutation: () -> Void
    ) throws {
        if !allowDuringRecordingRecovery,
           !RecordingsLibraryStorage.allowsMutations(in: metadataURL.deletingLastPathComponent())
        {
            throw StorageError.unreadableMetadata
        }
        let previous = batches
        mutation()
        do {
            try save()
        } catch {
            batches = previous
            throw error
        }
    }

    private func unique(_ ids: [UUID]) -> [UUID] {
        var seen = Set<UUID>()
        return ids.filter { seen.insert($0).inserted }
    }

    private static func defaultName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateFormat = "MMM d, yyyy, HH:mm"
        return "Batch — \(formatter.string(from: date))"
    }
}
