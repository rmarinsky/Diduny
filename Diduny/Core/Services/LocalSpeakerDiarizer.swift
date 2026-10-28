import Foundation
#if arch(arm64)
import FluidAudio
#endif

/// On-device voice detection (FluidAudio offline diarizer), for speaker labels.
/// Apple Silicon with macOS 15+ only: the diarizer crashes in Apple's BNNS on macOS 14, and its
/// Intel runtime is unverified (spec FR-3).
actor LocalSpeakerDiarizer {
    static let shared = LocalSpeakerDiarizer()

    /// Approximate size of the one-time model download (offline segmentation, embedding, fbank, PLDA).
    static let modelDownloadMegabytes = 22

    nonisolated static var isSupported: Bool {
        #if arch(arm64)
        if #available(macOS 15, *) { return true }
        #endif
        return false
    }

    nonisolated static var isRunningOnIntel: Bool {
        #if arch(arm64)
        false
        #else
        true
        #endif
    }

    /// True once the models are on disk; loading them still compiles on first use.
    nonisolated static var modelsDownloaded: Bool {
        #if arch(arm64)
        let directory = OfflineDiarizerModels.defaultModelsDirectory()
            .appendingPathComponent(Repo.diarizer.folderName, isDirectory: true)
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return contents.contains { $0.hasSuffix(".mlmodelc") }
        #else
        false
        #endif
    }

    enum DiarizerError: LocalizedError {
        case unsupported

        var errorDescription: String? {
            String(localized: "Speaker identification needs a Mac with Apple silicon and macOS 15 or later.")
        }
    }

    #if arch(arm64)
    /// One shared preparation: Settings and the queue may ask at the same time.
    private var preparation: Task<OfflineDiarizerManager, Error>?

    private func preparedManager() async throws -> OfflineDiarizerManager {
        guard Self.isSupported else { throw DiarizerError.unsupported }
        if preparation == nil {
            preparation = Task {
                let manager = OfflineDiarizerManager()
                try await manager.prepareModels()
                return manager
            }
        }
        do {
            return try await preparation!.value
        } catch {
            preparation = nil // allow a retry after a failed download
            throw error
        }
    }
    #endif

    /// Downloads (first time) and loads the models.
    func prepareModels() async throws {
        #if arch(arm64)
        _ = try await preparedManager()
        #else
        throw DiarizerError.unsupported
        #endif
    }

    /// Speaker turns and voice fingerprints in a mono audio file (any format; converted to 16 kHz).
    func diarize(fileURL: URL) async throws -> SpeakerLabeling.Diarization {
        #if arch(arm64)
        let result = try await preparedManager().process(fileURL)
        return SpeakerLabeling.Diarization(
            turns: result.segments.map {
                SpeakerLabeling.Turn(
                    speakerId: $0.speakerId,
                    start: TimeInterval($0.startTimeSeconds),
                    end: TimeInterval($0.endTimeSeconds)
                )
            },
            embeddings: result.speakerDatabase ?? [:]
        )
        #else
        throw DiarizerError.unsupported
        #endif
    }

    /// Normalised voice fingerprint of the person who talks most in `samples` (16 kHz mono), for enrollment.
    func dominantVoiceEmbedding(samples: [Float]) async throws -> [Float]? {
        #if arch(arm64)
        let result = try await preparedManager().process(audio: samples)
        let diarization = SpeakerLabeling.Diarization(
            turns: result.segments.map {
                SpeakerLabeling.Turn(
                    speakerId: $0.speakerId,
                    start: TimeInterval($0.startTimeSeconds),
                    end: TimeInterval($0.endTimeSeconds)
                )
            },
            embeddings: result.speakerDatabase ?? [:]
        )
        guard let speaker = SpeakerLabeling.meSpeakerId(in: diarization, voiceProfile: nil),
              let embedding = diarization.embeddings[speaker]
        else { return nil }
        return SpeakerLabeling.normalized(embedding)
        #else
        throw DiarizerError.unsupported
        #endif
    }
}
