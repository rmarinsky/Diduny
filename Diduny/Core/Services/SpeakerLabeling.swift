import Foundation

/// Who said each segment of a local (Whisper) transcript.
/// Spec: `docs/specs/draft-local-speaker-labels.md`; design: `docs/design/local-speaker-labels.md`.
///
/// - A (every Mac): the louder channel of the meeting's 2-channel file → "Me" (mic) / "Others" (system).
/// - B (voice detection): speakers found on each channel → "Me", "Speaker N (room)", "Speaker N (remote)";
///   recordings without a 2-channel file get plain "Speaker N".
enum SpeakerLabeling {
    enum Side: Equatable {
        case microphone
        case system
    }

    /// One speaker turn from voice detection, in seconds from the start of the audio.
    struct Turn: Equatable {
        let speakerId: String
        let start: TimeInterval
        let end: TimeInterval
    }

    /// Voice detection result for one channel (or for a mono recording).
    struct Diarization: Equatable {
        var turns: [Turn]
        /// Voice fingerprint per speaker id.
        var embeddings: [String: [Float]]
    }

    /// Voice-profile match thresholds (spec FR-4, starting values).
    static let maxMatchDistance: Float = 0.40
    static let minMatchGap: Float = 0.10

    // MARK: - A: louder channel

    /// The louder channel during each segment, from per-frame energy of each channel
    /// (`MeetingTracksReader.Envelope`). A tie keeps the previous segment's side.
    static func sides(for segments: [TimedTranscriptSegment], envelope: MeetingTracksReader.Envelope) -> [Side] {
        var previous = Side.system
        return segments.indices.map { index in
            let (start, end) = bounds(of: index, in: segments)
            let from = Int(start * envelope.framesPerSecond)
            let to = Int((end * envelope.framesPerSecond).rounded(.up))
            let micEnergy = sum(envelope.mic, from: from, to: to)
            let systemEnergy = sum(envelope.system, from: from, to: to)
            if micEnergy != systemEnergy {
                previous = micEnergy > systemEnergy ? .microphone : .system
            }
            return previous
        }
    }

    // MARK: - Labels

    /// Labels for a meeting with a 2-channel file. A channel without voice detection keeps its A label.
    static func labelByTracks(
        _ segments: [TimedTranscriptSegment],
        sides: [Side],
        mic: Diarization?,
        system: Diarization?,
        voiceProfile: [Float]?
    ) -> [TimedTranscriptSegment] {
        let me = mic.flatMap { meSpeakerId(in: $0, voiceProfile: voiceProfile) }
        var numbers = SpeakerNumbers(first: 2) // "Me" is never numbered; others start at 2.
        return segments.enumerated().map { index, segment in
            let side = index < sides.count ? sides[index] : .system
            let (start, end) = bounds(of: index, in: segments)
            let label: String
            switch side {
            case .microphone:
                if let mic, let speaker = dominantSpeaker(in: mic.turns, from: start, to: end), speaker != me {
                    label = String(localized: "Speaker \(numbers.number(for: "mic:\(speaker)")) (room)")
                } else {
                    label = String(localized: "Me")
                }
            case .system:
                if let system, let speaker = dominantSpeaker(in: system.turns, from: start, to: end) {
                    label = String(localized: "Speaker \(numbers.number(for: "system:\(speaker)")) (remote)")
                } else {
                    label = String(localized: "Others")
                }
            }
            return segment.withSpeaker(label)
        }
    }

    /// Labels for a recording without a 2-channel file (imports, older meetings): plain "Speaker N".
    static func labelByVoice(_ segments: [TimedTranscriptSegment], diarization: Diarization) -> [TimedTranscriptSegment] {
        var numbers = SpeakerNumbers(first: 1)
        return segments.enumerated().map { index, segment in
            let (start, end) = bounds(of: index, in: segments)
            guard let speaker = dominantSpeaker(in: diarization.turns, from: start, to: end) else { return segment }
            return segment.withSpeaker(String(localized: "Speaker \(numbers.number(for: speaker))"))
        }
    }

    // MARK: - "Me"

    /// The enrolled voice when it clearly matches one mic speaker, otherwise the mic speaker who talks most.
    static func meSpeakerId(in mic: Diarization, voiceProfile: [Float]?) -> String? {
        if let voiceProfile, let match = matchingSpeaker(voiceProfile, in: mic.embeddings) {
            return match
        }
        var talkTime: [String: TimeInterval] = [:]
        for turn in mic.turns {
            talkTime[turn.speakerId, default: 0] += turn.end - turn.start
        }
        return talkTime.max { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value }?.key
    }

    /// Closest speaker within `maxMatchDistance` and at least `minMatchGap` closer than the runner-up.
    static func matchingSpeaker(_ profile: [Float], in embeddings: [String: [Float]]) -> String? {
        let distances = embeddings
            .compactMap { id, embedding in cosineDistance(profile, embedding).map { (id, $0) } }
            .sorted { $0.1 < $1.1 }
        guard let best = distances.first, best.1 < maxMatchDistance else { return nil }
        if distances.count > 1, distances[1].1 - best.1 < minMatchGap { return nil }
        return best.0
    }

    static func normalized(_ vector: [Float]) -> [Float]? {
        let norm = sqrt(vector.reduce(0) { $0 + $1 * $1 })
        guard norm > 0, norm.isFinite else { return nil }
        return vector.map { $0 / norm }
    }

    static func cosineDistance(_ a: [Float], _ b: [Float]) -> Float? {
        guard a.count == b.count, let a = normalized(a), let b = normalized(b) else { return nil }
        return 1 - zip(a, b).reduce(0) { $0 + $1.0 * $1.1 }
    }

    // MARK: - Helpers

    private struct SpeakerNumbers {
        private var assigned: [String: Int] = [:]
        private var next: Int

        init(first: Int) {
            next = first
        }

        /// Stable number per key, in order of first appearance.
        mutating func number(for key: String) -> Int {
            if let number = assigned[key] { return number }
            assigned[key] = next
            next += 1
            return assigned[key]!
        }
    }

    /// Segment span in seconds; a missing end runs to the next segment (or 1 s).
    private static func bounds(of index: Int, in segments: [TimedTranscriptSegment]) -> (TimeInterval, TimeInterval) {
        let segment = segments[index]
        let start = TimeInterval(segment.startMilliseconds) / 1000
        let fallbackEnd = index + 1 < segments.count
            ? TimeInterval(segments[index + 1].startMilliseconds) / 1000
            : start + 1
        let end = segment.endMilliseconds.map { TimeInterval($0) / 1000 } ?? fallbackEnd
        return (start, max(end, start))
    }

    /// Speaker with the most overlap with `start...end`; nil when nobody overlaps.
    private static func dominantSpeaker(in turns: [Turn], from start: TimeInterval, to end: TimeInterval) -> String? {
        var overlap: [String: TimeInterval] = [:]
        for turn in turns {
            let shared = min(end, turn.end) - max(start, turn.start)
            if shared > 0 { overlap[turn.speakerId, default: 0] += shared }
        }
        return overlap.max { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value }?.key
    }

    private static func sum(_ values: [Float], from: Int, to: Int) -> Float {
        let lower = min(max(0, from), values.count)
        let upper = min(max(lower, to), values.count)
        return values[lower ..< upper].reduce(0, +)
    }
}

extension TimedTranscriptSegment {
    func withSpeaker(_ speaker: String) -> TimedTranscriptSegment {
        TimedTranscriptSegment(
            startMilliseconds: startMilliseconds,
            endMilliseconds: endMilliseconds,
            speaker: speaker,
            text: text
        )
    }
}
