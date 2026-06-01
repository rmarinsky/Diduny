@testable import Diduny
import XCTest

/// Tests for `InProgressRecordingStore` (RLR-M1).
///
/// Each test uses an isolated temp directory as `baseDirectory:` so the user's
/// Application Support is never polluted.
final class InProgressRecordingStoreTests: XCTestCase {
    // MARK: - Helpers

    /// Creates an isolated store backed by a fresh temp directory.
    private func makeStore() throws -> (InProgressRecordingStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let store = try InProgressRecordingStore(baseDirectory: dir)
        return (store, dir)
    }

    private func sampleManifest(id: UUID = UUID()) -> InProgressRecordingManifest {
        InProgressRecordingManifest(
            id: id,
            schemaVersion: 1,
            type: .meeting,
            startedAt: Date(timeIntervalSince1970: 1_748_000_000),
            sourceDevice: nil,
            audioConfig: InProgressRecordingManifest.AudioConfig(
                sampleRate: 48000,
                channels: 1,
                bitDepth: 16
            ),
            chunks: [
                InProgressRecordingManifest.ChunkEntry(
                    index: 1,
                    filename: "chunk_001.wav",
                    byteCount: 0,
                    durationSeconds: 0,
                    closedAt: nil
                )
            ],
            lastWriteAt: Date(timeIntervalSince1970: 1_748_000_000),
            recordingInterruptedBySleep: false
        )
    }

    // MARK: - 1. beginRecording_createsDirectory

    func test_chunkURL_createsDirectory() async throws {
        let (store, _) = try makeStore()
        let id = UUID()

        let chunkURL = try await store.chunkURL(for: id)

        let dirURL = chunkURL.deletingLastPathComponent()
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: dirURL.path),
            "In-progress recording directory should exist after requesting chunkURL"
        )
        XCTAssertEqual(chunkURL.lastPathComponent, "chunk_001.wav")
    }

    // MARK: - 2. writeManifest_roundTrip

    func test_writeManifest_roundTrip() async throws {
        let (store, _) = try makeStore()
        let id = UUID()
        var manifest = sampleManifest(id: id)
        manifest.chunks[0].byteCount = 28_800_000
        manifest.chunks[0].durationSeconds = 300.0
        manifest.chunks[0].closedAt = Date(timeIntervalSince1970: 1_748_000_300)

        try await store.writeManifest(manifest, for: id)
        let read = try await store.readManifest(for: id)

        let decoded = try XCTUnwrap(read, "readManifest should return the written manifest")
        XCTAssertEqual(decoded.id, id)
        XCTAssertEqual(decoded.schemaVersion, 1)
        XCTAssertEqual(decoded.type, .meeting)
        XCTAssertEqual(decoded.chunks.count, 1)
        XCTAssertEqual(decoded.chunks[0].byteCount, 28_800_000)
        XCTAssertEqual(decoded.chunks[0].durationSeconds, 300.0, accuracy: 0.001)
        XCTAssertFalse(decoded.recordingInterruptedBySleep)
        // closedAt round-trip (ISO-8601 truncates to seconds)
        let closedAt = try XCTUnwrap(decoded.chunks[0].closedAt)
        XCTAssertEqual(
            closedAt.timeIntervalSince1970,
            1_748_000_300,
            accuracy: 1.0,
            "closedAt should survive ISO-8601 round-trip within 1 second"
        )
    }

    // MARK: - 3. writeManifest_atomic_temp_cleaned

    func test_writeManifest_noTempFileRemains() async throws {
        let (store, _) = try makeStore()
        let id = UUID()
        let manifest = sampleManifest(id: id)

        try await store.writeManifest(manifest, for: id)
        let dir = try await store.directoryURL(for: id)

        let contents = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        let hasTmp = contents.contains { $0.hasSuffix(".tmp") }
        XCTAssertFalse(hasTmp, "No .tmp file should remain after a successful writeManifest")
    }

    // MARK: - 4. readManifest_missing_returnsNil

    func test_readManifest_missingID_returnsNil() async throws {
        let (store, _) = try makeStore()
        let unknownID = UUID()

        // Should not throw, should return nil
        let result = try await store.readManifest(for: unknownID)
        XCTAssertNil(result, "readManifest for a UUID with no directory should return nil")
    }

    // MARK: - 5. cleanup_removesDirectory

    func test_cleanup_removesDirectory() async throws {
        let (store, _) = try makeStore()
        let id = UUID()

        // Write something so the directory exists
        try await store.writeManifest(sampleManifest(id: id), for: id)
        let dir = try await store.directoryURL(for: id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path), "Directory should exist before cleanup")

        try await store.cleanup(recordingId: id)

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: dir.path),
            "Directory should be removed after cleanup"
        )
    }

    // MARK: - 6. allInProgressRecordingIDs_listsExistingDirs

    func test_allInProgressRecordingIDs_filtersNonUUIDs() async throws {
        let (store, baseDir) = try makeStore()

        let id1 = UUID()
        let id2 = UUID()

        // Seed two valid UUID directories
        try await store.writeManifest(sampleManifest(id: id1), for: id1)
        try await store.writeManifest(sampleManifest(id: id2), for: id2)

        // Seed one garbage-named directory (should be ignored)
        let garbageDir = baseDir.appendingPathComponent("not-a-uuid")
        try FileManager.default.createDirectory(at: garbageDir, withIntermediateDirectories: true)

        let ids = try await store.allInProgressRecordingIDs()

        XCTAssertEqual(ids.count, 2, "Should return exactly 2 UUID entries, ignoring non-UUID dirs")
        XCTAssertTrue(ids.contains(id1), "Should contain id1")
        XCTAssertTrue(ids.contains(id2), "Should contain id2")
    }

    func test_init_throwsWhenBaseDirectoryCannotBeCreated() throws {
        let blockedFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("InProgressRecordingStoreTests-\(UUID().uuidString)")
        try Data("not a directory".utf8).write(to: blockedFile)
        defer { try? FileManager.default.removeItem(at: blockedFile) }

        let impossibleDirectory = blockedFile.appendingPathComponent("child")
        XCTAssertThrowsError(try InProgressRecordingStore(baseDirectory: impossibleDirectory))
    }
}
