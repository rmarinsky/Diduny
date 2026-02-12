import AVFoundation
import Foundation

@MainActor
final class AmbientListeningService {
    private(set) var isListening = false

    var onWakeWordDetected: (() -> Void)?

    private var audioEngine: AVAudioEngine?
    private var rollingBuffer: [Float] = []
    private let bufferDurationSeconds: Double = 2.0
    private let sampleRate: Double = 16000
    private var processingTask: Task<Void, Never>?
    private var whisperService: WhisperTranscriptionService?

    private var maxBufferSamples: Int {
        Int(sampleRate * bufferDurationSeconds)
    }

    func start() {
        guard !isListening else { return }

        let settings = SettingsStorage.shared
        guard settings.ambientListeningEnabled else { return }
        guard !settings.wakeWord.isEmpty else {
            Log.app.info("Ambient listening: no wake word configured")
            return
        }

        // Check that a Whisper tiny model is downloaded
        let tinyModel = WhisperModelManager.availableModels.first { $0.name == "ggml-tiny" || $0.name == "ggml-tiny.en" }
        guard let model = tinyModel, WhisperModelManager.shared.isModelDownloaded(model) else {
            Log.app.info("Ambient listening: tiny Whisper model not downloaded")
            return
        }

        let service = WhisperTranscriptionService()
        service.modelNameOverride = model.name
        whisperService = service

        do {
            try startAudioCapture()
            isListening = true
            startProcessingLoop()
            Log.app.info("Ambient listening started with wake word: '\(settings.wakeWord)'")
        } catch {
            Log.app.error("Ambient listening failed to start: \(error.localizedDescription)")
        }
    }

    func stop() {
        isListening = false
        processingTask?.cancel()
        processingTask = nil
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil
        rollingBuffer.removeAll()
        whisperService = nil
        Log.app.info("Ambient listening stopped")
    }

    // MARK: - Audio Capture

    private func startAudioCapture() throws {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        // Convert to 16kHz mono
        guard let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false) else {
            throw WhisperError.audioConversionFailed
        }

        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw WhisperError.audioConversionFailed
        }

        let bufferSize = AVAudioFrameCount(inputFormat.sampleRate * 0.1) // 100ms chunks
        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }

            let frameCount = AVAudioFrameCount(targetFormat.sampleRate * Double(buffer.frameLength) / inputFormat.sampleRate)
            guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCount) else { return }

            var error: NSError?
            let status = converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }

            guard status != .error, error == nil,
                  let channelData = convertedBuffer.floatChannelData
            else { return }

            let samples = Array(UnsafeBufferPointer(start: channelData[0], count: Int(convertedBuffer.frameLength)))

            Task { @MainActor [weak self] in
                self?.appendSamples(samples)
            }
        }

        engine.prepare()
        try engine.start()
        audioEngine = engine
    }

    private func appendSamples(_ samples: [Float]) {
        rollingBuffer.append(contentsOf: samples)
        if rollingBuffer.count > maxBufferSamples {
            rollingBuffer.removeFirst(rollingBuffer.count - maxBufferSamples)
        }
    }

    // MARK: - Wake Word Detection

    private func startProcessingLoop() {
        processingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2.5))
                guard !Task.isCancelled else { break }
                await self?.processBuffer()
            }
        }
    }

    private func processBuffer() async {
        guard isListening,
              rollingBuffer.count >= Int(sampleRate) // At least 1 second of audio
        else { return }

        let samples = rollingBuffer
        let wakeWord = SettingsStorage.shared.wakeWord.lowercased()

        guard let service = whisperService else { return }

        do {
            let text = try await service.transcribeRawSamples(samples)
            let lowered = text.lowercased()

            if lowered.contains(wakeWord) {
                Log.app.info("Wake word detected: '\(wakeWord)' in '\(text.prefix(60))'")
                rollingBuffer.removeAll()
                onWakeWordDetected?()
            }
        } catch {
            // Silently ignore transcription errors in ambient mode
        }
    }
}
