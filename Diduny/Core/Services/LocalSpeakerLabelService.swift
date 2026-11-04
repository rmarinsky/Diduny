import Foundation

/// One-time download of the voice detection models, shared by Settings and the queue.
@Observable
@MainActor
final class SpeakerModelManager {
    enum State: Equatable {
        case notDownloaded
        case downloading
        case ready
        case failed
    }

    static let shared = SpeakerModelManager()

    private(set) var state: State = LocalSpeakerDiarizer.modelsDownloaded ? .ready : .notDownloaded

    /// Starts the download unless it is already done or running. Meetings finish with
    /// "Me / Others" until it completes (no waiting).
    func downloadIfNeeded() {
        guard LocalSpeakerDiarizer.isSupported, state == .notDownloaded || state == .failed else { return }
        state = .downloading
        Task {
            do {
                try await LocalSpeakerDiarizer.shared.prepareModels()
                state = .ready
            } catch {
                Log.app.error("Speaker model download failed: \(error.localizedDescription, privacy: .public)")
                state = .failed
            }
        }
    }
}

/// Adds speaker labels to a local (Whisper) transcript after transcription.
/// Never throws: when labelling fails the transcript is returned as it was, or with the
/// "Me / Others" labels when the meeting has a 2-channel file (spec FR-3, AC-4).
@MainActor
enum LocalSpeakerLabelService {
    static func label(
        _ transcript: GeneratedTranscript,
        recording: Recording,
        tracksURL: URL?,
        audioURL: URL,
        onIdentifyingSpeakers: () -> Void
    ) async -> GeneratedTranscript {
        guard [.meeting, .fileTranscription].contains(recording.type), !transcript.segments.isEmpty else {
            return transcript
        }

        let useVoice = voiceDetectionReady()
        let workDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("speaker-labels-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: workDirectory) }

        let labelled: [TimedTranscriptSegment]
        if let tracksURL {
            guard let tracks = await readTracks(tracksURL, range: recording.trimRange, splitInto: useVoice ? workDirectory : nil)
            else { return transcript }
            let sides = SpeakerLabeling.sides(for: transcript.segments, envelope: tracks.envelope)
            var mic: SpeakerLabeling.Diarization?
            var system: SpeakerLabeling.Diarization?
            if useVoice {
                onIdentifyingSpeakers()
                // A silent channel (muted mic, no remote audio) is skipped, never an error.
                if tracks.envelope.micTotal > silenceEnergy, let url = tracks.micURL {
                    mic = await diarize(url)
                }
                if tracks.envelope.systemTotal > silenceEnergy, let url = tracks.systemURL {
                    system = await diarize(url)
                }
            }
            labelled = SpeakerLabeling.labelByTracks(
                transcript.segments,
                sides: sides,
                mic: mic,
                system: system,
                voiceProfile: VoiceProfileStore.shared.load()?.embedding
            )
        } else {
            // Imports and meetings recorded before the 2-channel file: voice detection only.
            guard useVoice else { return transcript }
            onIdentifyingSpeakers()
            guard let diarization = await diarize(audioURL) else { return transcript }
            labelled = SpeakerLabeling.labelByVoice(transcript.segments, diarization: diarization)
        }

        guard labelled.contains(where: { $0.speaker != nil }) else { return transcript }
        return GeneratedTranscript(
            text: DiarizedTranscriptFormatter.format(labelledSegments: labelled),
            segments: labelled
        )
    }

    /// Sum of squared samples below which a channel counts as silent.
    private static let silenceEnergy: Float = 1

    private static func voiceDetectionReady() -> Bool {
        guard LocalSpeakerDiarizer.isSupported, SettingsStorage.shared.speakerIdentificationEnabled else {
            return false
        }
        guard LocalSpeakerDiarizer.modelsDownloaded else {
            SpeakerModelManager.shared.downloadIfNeeded()
            return false
        }
        return true
    }

    private static func readTracks(
        _ url: URL,
        range: AudioTrimRange?,
        splitInto directory: URL?
    ) async -> MeetingTracksReader.Output? {
        do {
            if let directory {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            return try await Task.detached(priority: .utility) {
                try MeetingTracksReader.read(url, range: range, channelFilesDirectory: directory)
            }.value
        } catch {
            Log.app.error("Speaker labels: reading tracks failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private static func diarize(_ url: URL) async -> SpeakerLabeling.Diarization? {
        do {
            return try await LocalSpeakerDiarizer.shared.diarize(fileURL: url)
        } catch {
            Log.app.error("Speaker labels: voice detection failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
