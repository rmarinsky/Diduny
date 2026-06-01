import Foundation
import os

/// Manages the `InProgressRecordings/` directory under Application Support.
///
/// Owns all chunk files and `manifest.json` for in-progress meeting recordings.
/// `RecordingsLibraryStorage` only receives finalized, stitched files — it is never
/// written to while a recording is in flight.
///
/// **M1 scope:** single chunk per recording (`chunk_001.wav`).
/// Chunk rotation is M3; orphan detection is M5a; sleep handling is M2.
actor InProgressRecordingStore {
    private static let sharedResult = Result { try InProgressRecordingStore() }

    static func sharedStore() throws -> InProgressRecordingStore {
        try sharedResult.get()
    }

    private let baseDirectory: URL
    private let fileManager: FileManager

    // MARK: - Init

    init(baseDirectory: URL? = nil, fileManager: FileManager = .default) throws {
        self.fileManager = fileManager
        if let baseDirectory {
            self.baseDirectory = baseDirectory
        } else {
            let bundleID = Bundle.main.bundleIdentifier ?? "Diduny"
            guard let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
                throw InProgressRecordingStoreError.applicationSupportDirectoryUnavailable
            }
            self.baseDirectory = appSupport
                .appendingPathComponent(bundleID)
                .appendingPathComponent("InProgressRecordings")
        }
        try fileManager.createDirectory(at: self.baseDirectory, withIntermediateDirectories: true)
    }

    // MARK: - Directory

    /// Returns (creating if absent) the per-recording subdirectory.
    func directoryURL(for recordingId: UUID) throws -> URL {
        let dir = baseDirectory.appendingPathComponent(recordingId.uuidString)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Chunk URL

    /// Returns the path for a chunk file.
    /// In M1 this is always `chunk_001.wav` (index defaults to 1).
    /// M3 will call with incrementing indices on rotation.
    func chunkURL(for recordingId: UUID, index: Int = 1) throws -> URL {
        let dir = try directoryURL(for: recordingId)
        return dir.appendingPathComponent(String(format: "chunk_%03d.wav", index))
    }

    // MARK: - Manifest

    /// Writes `manifest.json` atomically via temp-file rename, then fsyncs.
    func writeManifest(_ manifest: InProgressRecordingManifest, for recordingId: UUID) throws {
        let dir = try directoryURL(for: recordingId)
        let manifestURL = dir.appendingPathComponent("manifest.json")
        let tempURL = dir.appendingPathComponent("manifest.json.tmp")

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(manifest)

        // Write to temp first
        try data.write(to: tempURL, options: .atomic)

        // Atomic rename into place
        if fileManager.fileExists(atPath: manifestURL.path) {
            _ = try fileManager.replaceItemAt(manifestURL, withItemAt: tempURL)
        } else {
            try fileManager.moveItem(at: tempURL, to: manifestURL)
        }

        // fsync the manifest so the kernel flushes to disk
        if let handle = try? FileHandle(forReadingFrom: manifestURL) {
            try handle.synchronize()
            try handle.close()
        }
    }

    /// Reads `manifest.json` for the given recording ID.
    /// Returns `nil` (not throws) when no directory or manifest exists — callers
    /// treat absence as "no in-progress recording with that ID."
    func readManifest(for recordingId: UUID) throws -> InProgressRecordingManifest? {
        let manifestURL = baseDirectory
            .appendingPathComponent(recordingId.uuidString)
            .appendingPathComponent("manifest.json")
        guard fileManager.fileExists(atPath: manifestURL.path) else { return nil }
        let data = try Data(contentsOf: manifestURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(InProgressRecordingManifest.self, from: data)
    }

    // MARK: - Discovery

    /// Returns UUIDs for which a directory exists under `InProgressRecordings/`.
    /// Used by the orphan detector (M5a). Directories with non-UUID names are silently ignored.
    func allInProgressRecordingIDs() throws -> [UUID] {
        guard fileManager.fileExists(atPath: baseDirectory.path) else { return [] }
        let entries = try fileManager.contentsOfDirectory(atPath: baseDirectory.path)
        return entries.compactMap { UUID(uuidString: $0) }
    }

    // MARK: - Cleanup

    /// Removes the per-recording directory after the file has been handed off to
    /// `RecordingsLibraryStorage` (or discarded by the user).
    func cleanup(recordingId: UUID) throws {
        let dir = baseDirectory.appendingPathComponent(recordingId.uuidString)
        if fileManager.fileExists(atPath: dir.path) {
            try fileManager.removeItem(at: dir)
        }
    }
}

enum InProgressRecordingStoreError: LocalizedError {
    case applicationSupportDirectoryUnavailable

    var errorDescription: String? {
        switch self {
        case .applicationSupportDirectoryUnavailable:
            "Application Support directory is unavailable."
        }
    }
}
