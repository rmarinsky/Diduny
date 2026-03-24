import Foundation

enum AudioCompressionService {
    private static let minimumSizeForCompression = 1_000_000 // 1 MB

    /// Compresses a WAV file to FLAC using macOS's built-in `afconvert`.
    /// Returns the FLAC file URL on success, or the original WAV URL on failure.
    static func compressToFLAC(wavURL: URL) async -> URL {
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: wavURL.path)[.size] as? Int) ?? 0
        guard fileSize >= minimumSizeForCompression else {
            Log.audio.info("FLAC compression skipped: file too small (\(fileSize) bytes)")
            return wavURL
        }

        let flacURL = wavURL.deletingPathExtension().appendingPathExtension("flac")

        do {
            try await runAfconvert(input: wavURL, output: flacURL)
            let flacSize = (try? FileManager.default.attributesOfItem(atPath: flacURL.path)[.size] as? Int) ?? 0
            let ratio = fileSize > 0 ? Double(flacSize) / Double(fileSize) : 1.0
            Log.audio.info("FLAC compression: \(fileSize) → \(flacSize) bytes (ratio \(String(format: "%.1f%%", ratio * 100)))")
            return flacURL
        } catch {
            Log.audio.warning("FLAC compression failed, using original WAV: \(error.localizedDescription)")
            try? FileManager.default.removeItem(at: flacURL)
            return wavURL
        }
    }

    /// Compresses in-memory WAV data to FLAC.
    /// Returns FLAC data on success, or the original WAV data on failure.
    static func compressToFLAC(audioData: Data) async -> Data {
        guard audioData.count >= minimumSizeForCompression else {
            Log.audio.info("FLAC compression skipped: data too small (\(audioData.count) bytes)")
            return audioData
        }

        let tempDir = FileManager.default.temporaryDirectory
        let wavURL = tempDir.appendingPathComponent(UUID().uuidString + ".wav")
        let flacURL = wavURL.deletingPathExtension().appendingPathExtension("flac")

        defer {
            try? FileManager.default.removeItem(at: wavURL)
            try? FileManager.default.removeItem(at: flacURL)
        }

        do {
            try audioData.write(to: wavURL)
            try await runAfconvert(input: wavURL, output: flacURL)
            let flacData = try Data(contentsOf: flacURL)
            let ratio = audioData.count > 0 ? Double(flacData.count) / Double(audioData.count) : 1.0
            Log.audio.info("FLAC compression: \(audioData.count) → \(flacData.count) bytes (ratio \(String(format: "%.1f%%", ratio * 100)))")
            return flacData
        } catch {
            Log.audio.warning("FLAC compression failed, using original WAV: \(error.localizedDescription)")
            return audioData
        }
    }

    // MARK: - Private

    private static func runAfconvert(input: URL, output: URL) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        process.arguments = ["-f", "FLAC", "-d", "flac", input.path, output.path]

        let errorPipe = Pipe()
        process.standardError = errorPipe

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { proc in
                if proc.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                    let errorMessage = String(data: errorData, encoding: .utf8) ?? "exit code \(proc.terminationStatus)"
                    continuation.resume(throwing: CompressionError.afconvertFailed(errorMessage))
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    enum CompressionError: LocalizedError {
        case afconvertFailed(String)

        var errorDescription: String? {
            switch self {
            case .afconvertFailed(let message):
                "afconvert failed: \(message)"
            }
        }
    }
}
