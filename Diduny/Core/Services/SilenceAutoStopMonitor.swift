import Foundation

/// Runs Silero VAD (shipped with whisper.cpp) over 16 kHz mono audio and turns
/// it into "Stop after silence" decisions. Audio arrives on capture threads;
/// detection runs on a private serial queue and each changed decision is
/// delivered, in order, on the main thread until `finish()` is called.
final class SilenceAutoStopMonitor: @unchecked Sendable {
    typealias Decision = SilenceAutoStopTimer.Decision

    static let modelResourceName = "ggml-silero-v6.2.0"
    /// Silero window at 16 kHz (32 ms).
    private static let frameSize = 512

    private let queue = DispatchQueue(label: "ua.com.rmarinsky.diduny.silence-vad", qos: .userInitiated)
    private let vad: OpaquePointer
    private let onDecision: @MainActor (Decision) -> Void
    /// Set by `finish()` on the main thread; decisions already queued for main are dropped.
    @MainActor private var isFinished = false

    // Accessed only on `queue`.
    private var gate = SpeechProbabilityGate()
    private var timer: SilenceAutoStopTimer
    private var pending: [Float] = []
    private var lastDecision: Decision = .keepRecording
    private var speechFrames = 0
    private var silenceFrames = 0
    private var silenceRMSSum: Float = 0

    init?(timeout: TimeInterval, onDecision: @escaping @MainActor (Decision) -> Void) {
        guard let path = Bundle.main.path(forResource: Self.modelResourceName, ofType: "bin") else {
            Log.audio.error("Silence auto-stop: VAD model missing from bundle")
            return nil
        }
        var params = whisper_vad_default_context_params()
        params.n_threads = 1
        params.use_gpu = false
        guard let vad = whisper_vad_init_from_file_with_params(path, params) else {
            Log.audio.error("Silence auto-stop: failed to load VAD model")
            return nil
        }

        self.vad = vad
        self.onDecision = onDecision
        timer = SilenceAutoStopTimer(timeout: timeout)
        Log.audio.info(
            "Silence auto-stop: timeout=\(timeout)s on=\(self.gate.onThreshold) off=\(self.gate.offThreshold)"
        )
    }

    deinit {
        whisper_vad_free(vad)
    }

    /// 16 kHz mono s16le PCM, as produced for realtime streaming.
    func append(pcm16 data: Data) {
        let samples: [Float] = data.withUnsafeBytes { raw in
            (0 ..< raw.count / 2).map { index in
                Float(raw.loadUnaligned(fromByteOffset: index * 2, as: Int16.self)) / 32768
            }
        }
        append(samples: samples)
    }

    /// 16 kHz mono Float samples.
    func append(samples: [Float]) {
        guard !samples.isEmpty else { return }
        queue.async { [weak self] in
            self?.process(samples)
        }
    }

    /// Stops delivering decisions and logs this recording's speech/silence statistics
    /// (no audio, no text).
    @MainActor
    func finish() {
        isFinished = true
        // Strong capture: callers drop the monitor right after calling this.
        queue.async { [self] in
            let meanRMS = silenceFrames > 0 ? silenceRMSSum / Float(silenceFrames) : 0
            let noiseFloorDB = 20 * log10(max(meanRMS, 0.00001))
            Log.audio.info(
                "Silence auto-stop: speechFrames=\(self.speechFrames) silenceFrames=\(self.silenceFrames) noiseFloor=\(Int(noiseFloorDB)) dBFS"
            )
        }
    }

    private func process(_ samples: [Float]) {
        pending.append(contentsOf: samples)
        let usable = pending.count / Self.frameSize * Self.frameSize
        guard usable > 0 else { return }

        let detected = pending.withUnsafeBufferPointer { buffer in
            whisper_vad_detect_speech_no_reset(vad, buffer.baseAddress, Int32(usable))
        }
        let frames = pending.prefix(usable)
        pending.removeFirst(usable)
        guard detected, let probs = whisper_vad_probs(vad) else { return }

        var heardSpeech = false
        for index in 0 ..< Int(whisper_vad_n_probs(vad)) {
            if gate.update(probability: probs[index]) {
                heardSpeech = true
                speechFrames += 1
            } else {
                silenceFrames += 1
                silenceRMSSum += Self.rms(frames.dropFirst(index * Self.frameSize).prefix(Self.frameSize))
            }
        }

        let decision = timer.update(isSpeech: heardSpeech, at: Date())
        guard decision != lastDecision else { return }
        lastDecision = decision
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.isFinished else { return }
                self.onDecision(decision)
            }
        }
    }

    private static func rms(_ frame: ArraySlice<Float>) -> Float {
        guard !frame.isEmpty else { return 0 }
        return (frame.reduce(0) { $0 + $1 * $1 } / Float(frame.count)).squareRoot()
    }
}
