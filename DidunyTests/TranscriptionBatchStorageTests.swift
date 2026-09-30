@testable import Diduny
import XCTest

@MainActor
final class TranscriptionBatchStorageTests: XCTestCase {
    private func makeRecording(
        id: UUID = UUID(),
        title: String,
        status: Recording.ProcessingStatus = .transcribed,
        transcript: String? = "Transcript"
    ) -> Recording {
        Recording(
            id: id,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            type: .fileTranscription,
            audioFileName: "\(id).m4a",
            durationSeconds: 60,
            fileSizeBytes: 42,
            status: status,
            transcriptionText: transcript,
            sourceDevice: nil,
            sourceFileName: title
        )
    }

    func test_storeRoundTripPreservesOrderedMembershipAndEditableMetadata() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptionBatchStorageTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstID = UUID()
        let secondID = UUID()
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)

        let store = try TranscriptionBatchStorage(baseDirectory: directory)
        let batch = try store.create(
            name: "  ",
            description: "Initial",
            recordingIDs: [firstID, secondID],
            createdAt: createdAt
        )
        XCTAssertTrue(batch.name.hasPrefix("Batch — "))
        XCTAssertTrue(batch.name.contains("2023"))
        try store.update(batchID: batch.id, name: "Research", description: "Updated")
        try store.close(batchID: batch.id)

        let reloaded = try TranscriptionBatchStorage(baseDirectory: directory)
        let persisted = try XCTUnwrap(reloaded.batches.first)
        XCTAssertEqual(persisted.name, "Research")
        XCTAssertEqual(persisted.description, "Updated")
        XCTAssertEqual(persisted.createdAt, createdAt)
        XCTAssertEqual(persisted.recordingIDs, [firstID, secondID])
        XCTAssertTrue(persisted.isProcessingClosed)
    }

    func test_storeRoundTripPreservesFailedWorkForRestartRetry() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptionBatchStorageTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try YouTubeRemoteMediaSource.normalize("https://youtu.be/dQw4w9WgXcQ")
        var item = BatchTranscriptionItem(remoteSource: source)
        item.status = .failed
        item.errorMessage = "Network unavailable"

        let store = try TranscriptionBatchStorage(baseDirectory: directory)
        let batch = try store.create(name: "Retry", recordingIDs: [])
        try store.replaceWorkItems([item], in: batch.id)
        try store.close(batchID: batch.id)

        let persisted = try XCTUnwrap(
            try TranscriptionBatchStorage(baseDirectory: directory).batches.first
        )
        XCTAssertEqual(persisted.workItems, [item])
        XCTAssertEqual(persisted.status(in: []), .completedWithIssues)
        XCTAssertTrue(persisted.markdown(recordings: []).contains("Network unavailable"))
    }

    func test_corruptMetadataIsPreservedAndBlocksWritesInsteadOfCrashing() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptionBatchStorageTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let metadataURL = directory.appendingPathComponent("transcription_batches.json")
        let corruptData = Data("not-json".utf8)
        try corruptData.write(to: metadataURL)

        let store = try TranscriptionBatchStorage(baseDirectory: directory)

        XCTAssertTrue(store.batches.isEmpty)
        XCTAssertNotNil(store.loadErrorMessage)
        XCTAssertThrowsError(try store.create(name: "Must not overwrite", recordingIDs: []))
        XCTAssertEqual(try Data(contentsOf: metadataURL), corruptData)
    }

    func test_unreadableExistingMetadataBlocksWrites() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptionBatchStorageTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let metadataURL = directory.appendingPathComponent("transcription_batches.json")
        try FileManager.default.createDirectory(at: metadataURL, withIntermediateDirectories: true)

        let store = try TranscriptionBatchStorage(baseDirectory: directory)

        XCTAssertNotNil(store.loadErrorMessage)
        XCTAssertThrowsError(try store.create(name: "Must not overwrite", recordingIDs: []))
        XCTAssertTrue(FileManager.default.fileExists(atPath: metadataURL.path))
    }

    func test_batchDerivesStatusSearchAndMarkdownFromCurrentRecordings() {
        let completed = makeRecording(title: "Quarterly planning", transcript: "Revenue grew")
        let failed = makeRecording(title: "Customer call", status: .failed, transcript: nil)
        let batch = TranscriptionBatch(
            name: "Planning",
            description: "Board preparation",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            isProcessingClosed: true,
            recordingIDs: [completed.id, failed.id]
        )
        let recordings = [completed, failed]

        XCTAssertEqual(batch.status(in: recordings), .completedWithIssues)
        XCTAssertTrue(batch.matches("revenue", recordings: recordings))
        XCTAssertTrue(batch.matches("customer", recordings: recordings))
        let markdown = batch.markdown(recordings: recordings)
        XCTAssertTrue(markdown.contains("# Planning"))
        XCTAssertTrue(markdown.contains("## Quarterly planning"))
        XCTAssertTrue(markdown.contains("Revenue grew"))
        XCTAssertTrue(markdown.contains("## Customer call"))
        XCTAssertTrue(markdown.contains("[Transcript unavailable — Failed]"))
    }

    func test_retryableWorkItemsExcludeCompletedAndDuplicateResults() {
        var failed = BatchTranscriptionItem(sourceURL: URL(fileURLWithPath: "/tmp/failed.m4a"))
        failed.status = .failed
        var completed = BatchTranscriptionItem(sourceURL: URL(fileURLWithPath: "/tmp/completed.m4a"))
        completed.status = .completed
        var duplicate = BatchTranscriptionItem(sourceURL: URL(fileURLWithPath: "/tmp/duplicate.m4a"))
        duplicate.status = .duplicate
        let batch = TranscriptionBatch(
            name: "Retry",
            isProcessingClosed: true,
            workItems: [failed, completed, duplicate]
        )

        XCTAssertEqual(batch.retryableWorkItems.map(\.id), [failed.id])
    }

    func test_inspectableWorkItemsRemainAvailableAfterBatchCloses() {
        var completed = BatchTranscriptionItem(
            sourceURL: URL(fileURLWithPath: "/tmp/completed.m4a")
        )
        completed.status = .completed
        let batch = TranscriptionBatch(
            name: "Completed",
            isProcessingClosed: true,
            workItems: [completed]
        )

        XCTAssertEqual(batch.inspectableWorkItems, [completed])
    }

    func test_inspectorStatusIsHiddenAfterSuccessfulProcessing() {
        XCTAssertTrue(BatchTranscriptionItem.Status.processing.showsInBatchInspector)
        XCTAssertTrue(BatchTranscriptionItem.Status.failed.showsInBatchInspector)
        XCTAssertFalse(BatchTranscriptionItem.Status.completed.showsInBatchInspector)
        XCTAssertFalse(BatchTranscriptionItem.Status.duplicate.showsInBatchInspector)
    }

    func test_markdownKeepsFailedAndCompletedWorkItemOrder() throws {
        let completed = makeRecording(title: "Second", transcript: "Done")
        var failedItem = BatchTranscriptionItem(sourceURL: URL(fileURLWithPath: "/tmp/first.m4a"))
        failedItem.status = .failed
        failedItem.errorMessage = "Failed first"
        var completedItem = BatchTranscriptionItem(sourceURL: URL(fileURLWithPath: "/tmp/second.m4a"))
        completedItem.status = .completed
        completedItem.recordingID = completed.id
        let batch = TranscriptionBatch(
            name: "Ordered",
            isProcessingClosed: true,
            recordingIDs: [completed.id],
            workItems: [failedItem, completedItem]
        )

        let markdown = batch.markdown(recordings: [completed])
        XCTAssertLessThan(
            try XCTUnwrap(markdown.range(of: "first.m4a")?.lowerBound),
            try XCTUnwrap(markdown.range(of: "Second")?.lowerBound)
        )
        XCTAssertTrue(markdown.contains("Type: File Transcription"))
        XCTAssertFalse(markdown.contains("/tmp/first.m4a"))
    }

    func test_removingRecordingCleansEveryBatchReference() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptionBatchStorageTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let sharedID = UUID()
        let store = try TranscriptionBatchStorage(baseDirectory: directory)
        _ = try store.create(name: "One", recordingIDs: [sharedID])
        _ = try store.create(name: "Two", recordingIDs: [UUID(), sharedID])

        try store.removeRecordingReferences(Set([sharedID]))

        XCTAssertTrue(store.batches.allSatisfy { !$0.recordingIDs.contains(sharedID) })
        let reloaded = try TranscriptionBatchStorage(baseDirectory: directory)
        XCTAssertTrue(reloaded.batches.allSatisfy { !$0.recordingIDs.contains(sharedID) })
    }

    func test_deleteReturnsAllAffectedRecordingIDsAndRemovesSharedReferences() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptionBatchStorageTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let sharedID = UUID()
        let ownedID = UUID()
        let store = try TranscriptionBatchStorage(baseDirectory: directory)
        let target = try store.create(name: "Target", recordingIDs: [ownedID, sharedID])
        let other = try store.create(name: "Other", recordingIDs: [sharedID])
        var sharedItem = BatchTranscriptionItem(sourceURL: URL(fileURLWithPath: "/tmp/shared.m4a"))
        sharedItem.recordingID = sharedID
        try store.replaceWorkItems([sharedItem], in: other.id)

        let affected = try store.delete(batchID: target.id).recordingIDs

        XCTAssertEqual(affected, Set([ownedID, sharedID]))
        XCTAssertEqual(store.batches.count, 1)
        XCTAssertEqual(store.batches[0].recordingIDs, [])
        XCTAssertEqual(store.batches[0].workItems, [])
    }

    func test_recordingAndBatchDeletionStayReferentiallyConsistent() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptionBatchStorageTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let batchStore = try TranscriptionBatchStorage(baseDirectory: directory)
        let recordingStore = RecordingsLibraryStorage(
            baseDirectory: directory,
            batchStorage: batchStore
        )
        let firstID = try XCTUnwrap(recordingStore.saveRecording(
            audioData: Data("first".utf8),
            type: .fileTranscription,
            duration: 1,
            transcriptionText: "First",
            forceSave: true
        ))
        let secondID = try XCTUnwrap(recordingStore.saveRecording(
            audioData: Data("second".utf8),
            type: .fileTranscription,
            duration: 1,
            transcriptionText: "Second",
            forceSave: true
        ))
        let target = try batchStore.create(name: "Target", recordingIDs: [firstID, secondID])
        _ = try batchStore.create(name: "Other", recordingIDs: [secondID])

        try recordingStore.deleteRecording(XCTUnwrap(
            recordingStore.recordings.first(where: { $0.id == firstID })
        ))
        XCTAssertTrue(batchStore.batches.allSatisfy { !$0.recordingIDs.contains(firstID) })

        recordingStore.deleteBatch(target)
        XCTAssertTrue(recordingStore.recordings.isEmpty)
        XCTAssertEqual(batchStore.batches.count, 1)
        XCTAssertTrue(batchStore.batches[0].recordingIDs.isEmpty)
    }

    func test_recordingDetailsUpdateThroughLibraryStorage() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecordingDetailsTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let batchStore = try TranscriptionBatchStorage(baseDirectory: directory)
        let store = RecordingsLibraryStorage(baseDirectory: directory, batchStorage: batchStore)
        let id = try XCTUnwrap(store.saveRecording(
            audioData: Data("audio".utf8),
            type: .fileTranscription,
            duration: 1,
            forceSave: true
        ))

        store.updateDetails(id: id, title: "  Interview  ", description: "  Research notes  ")

        let recording = try XCTUnwrap(store.recordings.first(where: { $0.id == id }))
        XCTAssertEqual(recording.title, "Interview")
        XCTAssertEqual(recording.description, "Research notes")
    }

    func test_audioExtensionOptimizationPreservesDetailsAndTranscriptHistory() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecordingOptimizationTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sourceURL = directory.appendingPathComponent("source.wav")
        try Data("fLaC-audio".utf8).write(to: sourceURL)
        let batchStore = try TranscriptionBatchStorage(baseDirectory: directory)
        let store = RecordingsLibraryStorage(baseDirectory: directory, batchStorage: batchStore)
        let id = try XCTUnwrap(store.saveRecording(
            audioURL: sourceURL,
            type: .fileTranscription,
            duration: 1,
            transcriptionText: "Original",
            forceSave: true
        ))
        store.updateDetails(id: id, title: "Interview", description: "Research notes")
        store.completeTranscription(
            id: id,
            status: .transcribed,
            text: "Local revision",
            segments: nil,
            kind: .local,
            provider: "local"
        )

        _ = await store.optimizeStoredRecordingIfNeeded(id: id)

        let recording = try XCTUnwrap(store.recordings.first(where: { $0.id == id }))
        XCTAssertEqual(recording.audioFileName, "\(id.uuidString).flac")
        XCTAssertEqual(recording.title, "Interview")
        XCTAssertEqual(recording.description, "Research notes")
        XCTAssertEqual(recording.resolvedTranscriptHistory.map(\.text), ["Original", "Local revision"])
    }

    func test_audioOptimizationStopsWhenDeletionRecoveryBeginsWhileCompressing() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecordingOptimizationRecoveryTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let batchStore = try TranscriptionBatchStorage(baseDirectory: directory)
        let compressionStarted = expectation(description: "compression started")
        var resumeCompression: CheckedContinuation<URL, Never>?
        let store = RecordingsLibraryStorage(
            baseDirectory: directory,
            batchStorage: batchStore,
            audioCompressor: { _ in
                await withCheckedContinuation { continuation in
                    resumeCompression = continuation
                    compressionStarted.fulfill()
                }
            }
        )
        var wavData = Data("RIFF".utf8)
        wavData.append(Data(repeating: 0, count: 4))
        wavData.append(Data("WAVE".utf8))
        let id = try XCTUnwrap(store.saveRecording(
            audioData: wavData,
            type: .fileTranscription,
            duration: 1,
            forceSave: true
        ))
        let sourceURL = try XCTUnwrap(store.recordings.first.map(store.audioFileURL))
        let replacementURL = sourceURL.deletingPathExtension().appendingPathExtension("flac")

        let optimization = Task { @MainActor in
            await store.optimizeStoredRecordingIfNeeded(id: id)
        }
        await fulfillment(of: [compressionStarted], timeout: 1)
        try Data("compressed".utf8).write(to: replacementURL)
        try JSONEncoder().encode(RecordingDeletionRecovery(
            recordings: store.recordings,
            stagedFiles: []
        )).write(to: directory.appendingPathComponent("recordings_delete_recovery.json"))
        try XCTUnwrap(resumeCompression).resume(returning: replacementURL)

        let result = await optimization.value
        XCTAssertEqual(result, sourceURL)
        XCTAssertEqual(store.recordings.first?.audioFileName, sourceURL.lastPathComponent)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: replacementURL.path))
    }

    func test_completedTranscriptionsAppendHistoryInsteadOfReplacingIt() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptHistoryTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let batchStore = try TranscriptionBatchStorage(baseDirectory: directory)
        let store = RecordingsLibraryStorage(baseDirectory: directory, batchStorage: batchStore)
        let id = try XCTUnwrap(store.saveRecording(
            audioData: Data("audio".utf8),
            type: .fileTranscription,
            duration: 1,
            transcriptionText: "Cloud original",
            generatedTranscriptProvenance: GeneratedTranscriptProvenance(provider: "cloud"),
            forceSave: true
        ))

        store.completeTranscription(
            id: id,
            status: .transcribed,
            text: "Local revision",
            segments: nil,
            kind: .local,
            provider: "local",
            modelIdentifier: "whisper-small"
        )
        store.completeTranscription(
            id: id,
            status: .translated,
            text: "Revisión local",
            segments: nil,
            translationTargetLanguageCode: "es",
            kind: .translation,
            provider: "cloud",
            sourceLanguageCode: "en"
        )

        let recording = try XCTUnwrap(store.recordings.first(where: { $0.id == id }))
        XCTAssertEqual(recording.transcriptionText, "Revisión local")
        XCTAssertEqual(recording.resolvedTranscriptHistory.map(\.text), [
            "Cloud original",
            "Local revision",
            "Revisión local"
        ])
        XCTAssertEqual(recording.resolvedTranscriptHistory.map(\.kind), [.cloud, .local, .translation])
        XCTAssertEqual(recording.resolvedTranscriptHistory[1].modelIdentifier, "whisper-small")
        XCTAssertEqual(recording.resolvedTranscriptHistory[2].sourceLanguageCode, "en")
        XCTAssertEqual(recording.resolvedTranscriptHistory[2].targetLanguageCode, "es")
    }

    func test_batchSearchAndMarkdownIncludeDetailsSourceAndEveryTranscriptVersion() throws {
        let source = try RemoteMediaSourceMetadata(
            provider: YouTubeRemoteMediaSource.provider,
            mediaID: "dQw4w9WgXcQ",
            canonicalURL: XCTUnwrap(URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ")),
            title: "Original YouTube title",
            channelName: "Channel",
            description: "YouTube source notes"
        )
        let recording = Recording(
            id: UUID(),
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            type: .fileTranscription,
            audioFileName: "video.m4a",
            durationSeconds: 65,
            fileSizeBytes: 42,
            status: .translated,
            transcriptionText: "Texto actual",
            sourceDevice: nil,
            remoteSource: source,
            title: "Customer workflow",
            description: "Research interview",
            transcriptHistory: [
                TranscriptVersion(
                    createdAt: Date(timeIntervalSince1970: 1_700_000_010),
                    kind: .cloud,
                    provider: "cloud",
                    sourceLanguageCode: "en",
                    text: "Original phrase"
                ),
                TranscriptVersion(
                    createdAt: Date(timeIntervalSince1970: 1_700_000_020),
                    kind: .translation,
                    provider: "cloud",
                    sourceLanguageCode: "en",
                    targetLanguageCode: "es",
                    text: "Texto actual"
                )
            ]
        )
        let batch = TranscriptionBatch(
            name: "Product research",
            description: "Onboarding",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            isProcessingClosed: true,
            recordingIDs: [recording.id]
        )

        XCTAssertTrue(batch.matches("Customer workflow", recordings: [recording]))
        XCTAssertTrue(batch.matches("Research interview", recordings: [recording]))
        XCTAssertTrue(batch.matches("Original phrase", recordings: [recording]))
        XCTAssertTrue(batch.matches("YouTube source notes", recordings: [recording]))

        let markdown = batch.markdown(recordings: [recording])
        XCTAssertTrue(markdown.contains("# Product research"))
        XCTAssertTrue(markdown.contains("Onboarding"))
        XCTAssertTrue(markdown.contains("## Customer workflow"))
        XCTAssertTrue(markdown.contains("Duration: 1:05"))
        XCTAssertTrue(markdown.contains("Research interview"))
        XCTAssertTrue(markdown.contains(source.canonicalURL.absoluteString))
        XCTAssertTrue(markdown.contains("### Cloud"))
        XCTAssertTrue(markdown.contains("Original phrase"))
        XCTAssertTrue(markdown.contains("### Translation · en → es"))
        XCTAssertTrue(markdown.contains("Texto actual"))
    }

    func test_deletingRecordingRemovesStoredMediaCheckpointAndBatchReferences() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecordingCascadeDeleteTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let checkpointDirectory = directory.appendingPathComponent("checkpoint", isDirectory: true)
        try FileManager.default.createDirectory(at: checkpointDirectory, withIntermediateDirectories: true)
        let checkpointURL = checkpointDirectory.appendingPathComponent("download.m4a")
        try Data("checkpoint".utf8).write(to: checkpointURL)

        let batchStore = try TranscriptionBatchStorage(baseDirectory: directory)
        let store = RecordingsLibraryStorage(baseDirectory: directory, batchStorage: batchStore)
        let id = try XCTUnwrap(store.saveRecording(
            audioData: Data("audio".utf8),
            type: .fileTranscription,
            duration: 1,
            forceSave: true
        ))
        let recording = try XCTUnwrap(store.recordings.first(where: { $0.id == id }))
        let storedMediaURL = store.audioFileURL(for: recording)
        var item = BatchTranscriptionItem(sourceURL: URL(fileURLWithPath: "/tmp/source.m4a"))
        item.recordingID = id
        item.downloadedAudioURL = checkpointURL
        let batch = try batchStore.create(name: "Delete", recordingIDs: [id])
        try batchStore.replaceWorkItems([item], in: batch.id)

        store.deleteRecording(recording)

        XCTAssertFalse(FileManager.default.fileExists(atPath: storedMediaURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: checkpointDirectory.path))
        XCTAssertTrue(batchStore.batches.allSatisfy { !$0.recordingIDs.contains(id) })
    }

    func test_commitFailureRestoresBatchReferenceWithoutDeletingCheckpoint() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecordingCheckpointRollbackTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let checkpointDirectory = directory.appendingPathComponent("checkpoint", isDirectory: true)
        try FileManager.default.createDirectory(at: checkpointDirectory, withIntermediateDirectories: true)
        let checkpointURL = checkpointDirectory.appendingPathComponent("download.m4a")
        try Data("checkpoint".utf8).write(to: checkpointURL)
        let batchStore = try TranscriptionBatchStorage(baseDirectory: directory)
        let store = RecordingsLibraryStorage(
            baseDirectory: directory,
            batchStorage: batchStore,
            deletionCommitWriter: { _, _ in false }
        )
        let id = try XCTUnwrap(store.saveRecording(
            audioData: Data("audio".utf8),
            type: .fileTranscription,
            duration: 1,
            forceSave: true
        ))
        let recording = try XCTUnwrap(store.recordings.first)
        var item = BatchTranscriptionItem(sourceURL: URL(fileURLWithPath: "/tmp/source.m4a"))
        item.recordingID = id
        item.downloadedAudioURL = checkpointURL
        let batch = try batchStore.create(name: "Protected", recordingIDs: [id])
        try batchStore.replaceWorkItems([item], in: batch.id)

        XCTAssertFalse(store.deleteRecording(recording))
        XCTAssertTrue(FileManager.default.fileExists(atPath: checkpointURL.path))
        XCTAssertEqual(batchStore.batches.first?.recordingIDs, [id])
        XCTAssertEqual(batchStore.batches.first?.workItems?.first?.downloadedAudioURL, checkpointURL)
    }

    func test_startupFinishesCheckpointCleanupPersistedInCommitJournal() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CommittedCheckpointCleanupTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let checkpointDirectory = directory.appendingPathComponent("checkpoint", isDirectory: true)
        try FileManager.default.createDirectory(at: checkpointDirectory, withIntermediateDirectories: true)
        let checkpointURL = checkpointDirectory.appendingPathComponent("download.m4a")
        try Data("checkpoint".utf8).write(to: checkpointURL)
        try JSONEncoder().encode(RecordingDeletionRecovery(
            recordings: [],
            stagedFiles: [],
            deferredBatchArtifactPaths: [checkpointURL.path]
        )).write(to: directory.appendingPathComponent("recordings_delete_commit.json"))
        try Data("[]".utf8).write(to: directory.appendingPathComponent("recordings_metadata.json"))
        let batchStore = try TranscriptionBatchStorage(baseDirectory: directory)

        _ = RecordingsLibraryStorage(baseDirectory: directory, batchStorage: batchStore)

        XCTAssertFalse(FileManager.default.fileExists(atPath: checkpointDirectory.path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("recordings_delete_commit.json").path
        ))
    }

    func test_failedBatchMetadataWriteRollsBackInMemoryReferences() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BatchDeleteRollbackTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let recordingID = UUID()
        let batchStore = try TranscriptionBatchStorage(baseDirectory: directory)
        let checkpointURL = directory.appendingPathComponent("checkpoint.m4a")
        try Data("checkpoint".utf8).write(to: checkpointURL)
        var item = BatchTranscriptionItem(sourceURL: URL(fileURLWithPath: "/tmp/source.m4a"))
        item.recordingID = recordingID
        item.downloadedAudioURL = checkpointURL
        let batch = try batchStore.create(name: "Protected", recordingIDs: [recordingID])
        try batchStore.replaceWorkItems([item], in: batch.id)
        let metadataURL = directory.appendingPathComponent("transcription_batches.json")
        try FileManager.default.removeItem(at: metadataURL)
        try FileManager.default.createDirectory(at: metadataURL, withIntermediateDirectories: true)

        XCTAssertThrowsError(try batchStore.removeRecordingReferences(Set([recordingID])))
        XCTAssertEqual(batchStore.batches.first?.recordingIDs, [recordingID])
        XCTAssertTrue(FileManager.default.fileExists(atPath: checkpointURL.path))
    }

    func test_failedRecordingMetadataWriteKeepsRecordingFileAndBatchReference() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecordingDeleteRollbackTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let batchStore = try TranscriptionBatchStorage(baseDirectory: directory)
        let store = RecordingsLibraryStorage(baseDirectory: directory, batchStorage: batchStore)
        let recordingID = try XCTUnwrap(store.saveRecording(
            audioData: Data("audio".utf8),
            type: .fileTranscription,
            duration: 1,
            forceSave: true
        ))
        let recording = try XCTUnwrap(store.recordings.first)
        _ = try batchStore.create(name: "Protected", recordingIDs: [recordingID])
        let metadataURL = directory.appendingPathComponent("recordings_metadata.json")
        try FileManager.default.removeItem(at: metadataURL)
        try FileManager.default.createDirectory(at: metadataURL, withIntermediateDirectories: true)

        XCTAssertFalse(store.deleteRecording(recording))

        XCTAssertTrue(store.recordings.contains(where: { $0.id == recordingID }))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.audioFileURL(for: recording).path))
        XCTAssertEqual(batchStore.batches.first?.recordingIDs, [recordingID])
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("recordings_delete_recovery.json").path
        ))
    }

    @MainActor
    func test_immediateSaveAfterStartupPreservesExistingRecordingMetadata() async throws {
        let originalPolicy = SettingsStorage.shared.dictationTranslationHistoryRetentionPolicy
        SettingsStorage.shared.dictationTranslationHistoryRetentionPolicy = .forever
        defer {
            SettingsStorage.shared.dictationTranslationHistoryRetentionPolicy = originalPolicy
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecordingStartupSaveTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let recordingsDirectory = directory.appendingPathComponent("Recordings")
        try FileManager.default.createDirectory(
            at: recordingsDirectory,
            withIntermediateDirectories: true
        )
        let existing = Recording(
            id: UUID(),
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            type: .fileTranscription,
            audioFileName: "existing.wav",
            durationSeconds: 1,
            fileSizeBytes: 8,
            status: .transcribed,
            transcriptionText: "Existing",
            sourceDevice: nil
        )
        try Data("existing".utf8).write(
            to: recordingsDirectory.appendingPathComponent(existing.audioFileName)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode([existing]).write(
            to: directory.appendingPathComponent("recordings_metadata.json"),
            options: .atomic
        )
        let batchStore = try TranscriptionBatchStorage(baseDirectory: directory)

        let store = RecordingsLibraryStorage(baseDirectory: directory, batchStorage: batchStore)
        let newID = try XCTUnwrap(store.saveRecording(
            audioData: Data("new".utf8),
            type: .fileTranscription,
            duration: 1,
            transcriptionText: "New",
            forceSave: true
        ))
        await Task.yield()
        try await Task.sleep(for: .milliseconds(100))

        let data = try Data(contentsOf: directory.appendingPathComponent("recordings_metadata.json"))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let persisted = try decoder.decode([Recording].self, from: data)
        XCTAssertEqual(Set(persisted.map(\.id)), Set([existing.id, newID]))
    }

    func test_startupRestoresRecordingMetadataFromDeletionRecoveryJournal() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecordingDeleteRecoveryTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let recordingsDirectory = directory.appendingPathComponent("Recordings")
        try FileManager.default.createDirectory(at: recordingsDirectory, withIntermediateDirectories: true)
        let recording = Recording(
            id: UUID(),
            createdAt: Date(),
            type: .fileTranscription,
            audioFileName: "recovered.m4a",
            durationSeconds: 1,
            fileSizeBytes: 5,
            status: .transcribed,
            transcriptionText: "Recovered",
            sourceDevice: nil,
            title: "Recovered"
        )
        let originalURL = recordingsDirectory.appendingPathComponent(recording.audioFileName)
        let stagedURL = recordingsDirectory.appendingPathComponent(".recovered.deleting-test")
        let recoveredBatch = TranscriptionBatch(
            name: "Recovered batch",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            recordingIDs: [recording.id]
        )
        try Data("audio".utf8).write(to: stagedURL)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(RecordingDeletionRecovery(
            recordings: [recording],
            batches: [recoveredBatch],
            stagedFiles: [RecordingDeletionStagedFile(
                originalPath: originalURL.path,
                stagedPath: stagedURL.path
            )]
        )).write(
            to: directory.appendingPathComponent("recordings_delete_recovery.json")
        )
        try Data("[]".utf8).write(to: directory.appendingPathComponent("recordings_metadata.json"))
        let batchStore = try TranscriptionBatchStorage(baseDirectory: directory)

        let store = RecordingsLibraryStorage(baseDirectory: directory, batchStorage: batchStore)
        for _ in 0 ..< 100 where store.recordings.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(store.recordings.map(\.id), [recording.id])
        XCTAssertEqual(batchStore.batches, [recoveredBatch])
        XCTAssertTrue(FileManager.default.fileExists(atPath: originalURL.path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("recordings_delete_recovery.json").path
        ))
    }

    func test_appliedDeletionRollbackIsNotReplayedAfterRemovalFailure() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppliedRecordingDeleteRecoveryTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let recordingsDirectory = directory.appendingPathComponent("Recordings")
        try FileManager.default.createDirectory(at: recordingsDirectory, withIntermediateDirectories: true)
        let recovered = Recording(
            id: UUID(),
            createdAt: Date(),
            type: .meeting,
            audioFileName: "recovered.m4a",
            durationSeconds: 1,
            fileSizeBytes: 5,
            status: .unprocessed,
            sourceDevice: nil
        )
        try Data("audio".utf8).write(
            to: recordingsDirectory.appendingPathComponent(recovered.audioFileName)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(RecordingDeletionRecovery(
            recordings: [recovered],
            stagedFiles: []
        )).write(to: directory.appendingPathComponent("recordings_delete_recovery.json"))
        try Data("[]".utf8).write(to: directory.appendingPathComponent("recordings_metadata.json"))
        let batchStore = try TranscriptionBatchStorage(baseDirectory: directory)
        let failingRemover: (URL) throws -> Void = { _ in
            throw CocoaError(.fileWriteNoPermission)
        }

        let firstLoad = RecordingsLibraryStorage(
            baseDirectory: directory,
            batchStorage: batchStore,
            deletionRecoveryRemover: failingRemover
        )
        let addedID = try XCTUnwrap(firstLoad.saveRecording(
            audioData: Data("new".utf8),
            type: .meeting,
            duration: 1,
            forceSave: true
        ))
        let secondLoad = RecordingsLibraryStorage(
            baseDirectory: directory,
            batchStorage: batchStore,
            deletionRecoveryRemover: failingRemover
        )

        XCTAssertEqual(Set(secondLoad.recordings.map(\.id)), Set([recovered.id, addedID]))
    }

    func test_unresolvedRecordingDeletionBlocksBatchMutation() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BlockedBatchMutationTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let batchStore = try TranscriptionBatchStorage(baseDirectory: directory)
        try JSONEncoder().encode(RecordingDeletionRecovery(
            recordings: [],
            stagedFiles: []
        )).write(to: directory.appendingPathComponent("recordings_delete_recovery.json"))

        XCTAssertThrowsError(try batchStore.create(name: "Blocked", recordingIDs: []))
        XCTAssertTrue(batchStore.batches.isEmpty)
    }

    func test_batchDeletionRejectsArtifactOutsideDidunyTemporaryDirectory() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BatchArtifactBoundaryTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let batchStore = try TranscriptionBatchStorage(baseDirectory: directory)
        var item = BatchTranscriptionItem(sourceURL: URL(fileURLWithPath: "/tmp/source.m4a"))
        item.downloadedAudioURL = URL(fileURLWithPath: "/Applications/not-a-diduny-checkpoint")
        let batch = try batchStore.create(name: "Protected", recordingIDs: [])
        try batchStore.replaceWorkItems([item], in: batch.id)

        XCTAssertThrowsError(try batchStore.delete(batchID: batch.id))
        XCTAssertEqual(batchStore.batches.map(\.id), [batch.id])
    }
}
