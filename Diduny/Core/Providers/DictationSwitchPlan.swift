import Foundation

/// WP-64 (N21): how a dictation or translation that changed engine mid-recording gets its text at Stop.
/// Pure. The spans come from `MeetingSwitchMachine`'s history, so a failed or cancelled switch leaves one span.
enum DictationSwitchPlan {
    enum Part: Equatable {
        /// Text the span's live engine produced.
        case live(span: Int)
        /// Frames [start, end) of the recording, transcribed by `engine` after Stop; nil end is the end.
        case afterStop(span: Int, engine: EngineID, startFrame: Int, endFrame: Int?)
    }

    /// A span's text and whether it is already in the target language.
    struct SpanText: Equatable {
        var text: String
        var translated: Bool
    }

    /// What a pick in the panel runs. Parakeet and an ElevenLabs model without realtime have no live text;
    /// a translation has no Whisper preview, as at Start.
    static func target(for engine: EngineID, elevenLabsLive: Bool, translating: Bool) -> MeetingEngineTarget {
        switch engine {
        case .parakeet: .afterStopOnly(engine)
        case .elevenLabs: elevenLabsLive ? .live(engine) : .afterStopOnly(engine)
        case .whisper: translating ? .afterStopOnly(engine) : .live(engine)
        case .didunyCloud, .appleSpeech: .live(engine)
        }
    }

    /// Whisper's live text is a preview, so its span is transcribed after Stop like an engine without live text.
    static func transcribesAfterStop(_ target: MeetingEngineTarget) -> Bool {
        !target.isLive || target.engine == .whisper
    }

    static func parts(_ history: MeetingEngineHistory) -> [Part] {
        history.spans.enumerated().map { index, span in
            let end = history.spans.indices.contains(index + 1) ? history.spans[index + 1].startFrame : nil
            return transcribesAfterStop(span.target)
                ? .afterStop(span: index, engine: span.target.engine, startFrame: span.startFrame, endFrame: end)
                : .live(span: index)
        }
    }

    /// The parts in recording order, one space between them. The audio of each part went to one engine only,
    /// so nothing repeats at a cut.
    static func compose(_ texts: [String]) -> String {
        texts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// The engine for a whole-recording fallback: `preferred`, unless a local engine was used and `preferred` is not
    /// local; then that local engine, so audio captured under a local engine is never uploaded.
    static func wholeFallbackEngine(used: [EngineID], preferred: EngineID) -> EngineID {
        guard !runsLocally(preferred), let local = used.first(where: runsLocally) else { return preferred }
        return local
    }

    /// The text of every part, in order. Span 0 that produced nothing live (its connect failed) is transcribed
    /// from its own audio by its own engine. A part that fails becomes `failedMarker`; the others are kept.
    /// `slice` nil (a layout the cut cannot range): the whole recording, by `wholeFallbackEngine`.
    static func collect(
        history: MeetingEngineHistory,
        liveTexts: [Int: SpanText],
        audio: Data,
        failedMarker: String,
        slice: (Data, Int, Int?) -> Data? = { slice(wav: $0, from: $1, to: $2) },
        transcribe: (EngineID, Data) async throws -> String
    ) async -> [SpanText] {
        var texts: [SpanText] = []
        let engines = history.spans.map(\.target.engine)
        for part in parts(history) {
            var part = part
            if case .live(span: 0) = part, (liveTexts[0]?.text ?? "").isEmpty {
                let end = history.spans.count > 1 ? history.spans[1].startFrame : nil
                part = .afterStop(span: 0, engine: engines[0], startFrame: 0, endFrame: end)
            }
            switch part {
            case let .live(span):
                texts.append(liveTexts[span] ?? .init(text: "", translated: false))
            case let .afterStop(_, engine, from, to):
                if let to, to <= from { continue }
                guard let audioPart = slice(audio, from, to) else {
                    let whole = wholeFallbackEngine(used: engines, preferred: engines.last ?? engine)
                    let text = try? await transcribe(whole, audio)
                    return [text.map { .init(text: $0, translated: false) } ?? .init(text: failedMarker, translated: true)]
                }
                do {
                    texts.append(.init(text: try await transcribe(engine, audioPart), translated: false))
                } catch {
                    // Not translated later: the marker stays as it is.
                    texts.append(.init(text: failedMarker, translated: true))
                }
            }
        }
        return texts
    }

    /// Engines whose audio never leaves this Mac.
    static func runsLocally(_ engine: EngineID) -> Bool {
        switch engine {
        case .whisper, .parakeet, .appleSpeech: true
        case .didunyCloud, .elevenLabs: false
        }
    }

    /// Frames [start, end) of a 16 kHz mono 16-bit PCM WAV as a new WAV. Nil when the data has another layout or
    /// the range is empty: the caller then transcribes the whole recording instead of guessing.
    static func slice(wav: Data, from start: Int, to end: Int?) -> Data? {
        let bytes = [UInt8](wav)
        func u32(_ at: Int) -> Int {
            Int(bytes[at]) | Int(bytes[at + 1]) << 8 | Int(bytes[at + 2]) << 16 | Int(bytes[at + 3]) << 24
        }
        func u16(_ at: Int) -> Int { Int(bytes[at]) | Int(bytes[at + 1]) << 8 }
        func tag(_ at: Int) -> String { String(decoding: bytes[at ..< at + 4], as: UTF8.self) }
        guard bytes.count >= 12, tag(0) == "RIFF", tag(8) == "WAVE" else { return nil }
        var offset = 12
        var formatOK = false
        while offset + 8 <= bytes.count {
            let id = tag(offset), size = u32(offset + 4), body = offset + 8
            if id == "fmt ", size >= 16, body + 16 <= bytes.count {
                formatOK = u16(body) == 1 && u16(body + 2) == 1 && u32(body + 4) == 16000 && u16(body + 14) == 16
            } else if id == "data" {
                guard formatOK else { return nil }
                let available = min(size, bytes.count - body) / 2
                let first = max(0, start), last = min(end ?? available, available)
                guard last > first else { return nil }
                return wavFile(pcm: Data(bytes[(body + first * 2) ..< (body + last * 2)]))
            }
            offset = body + size + (size & 1)
        }
        return nil
    }

    static func wavFile(pcm: Data) -> Data {
        var data = Data()
        func append(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func append(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + pcm.count))
        data.append(contentsOf: Array("WAVEfmt ".utf8)); append(UInt32(16))
        append(UInt16(1)); append(UInt16(1)); append(UInt32(16000)); append(UInt32(32000))
        append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(UInt32(pcm.count))
        data.append(pcm)
        return data
    }
}
