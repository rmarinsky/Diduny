import Foundation
import os

final class CloudTranscriptionService: TranscriptionServiceProtocol {
    private static let defaultModel = "stt-async-v4"

    private var proxyTranscriptionsURL: String {
        let proxyBase = SettingsStorage.shared.proxyBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return "\(proxyBase)/api/v1/transcriptions"
    }

    private var model: String {
        RemoteConfigService.shared.sttModel(default: Self.defaultModel)
    }

    private let maxAudioBytesForSpeechPrecheck = 25 * 1024 * 1024
    private let strictSpeechPrecheck = false

    // Protocol conformance method
    func transcribe(audioData: Data) async throws -> String {
        try await transcribe(audioData: audioData, language: nil)
    }

    func transcribe(audioData: Data, language: String?) async throws -> String {
        Log.transcription.info("transcribe: BEGIN, audioData size = \(audioData.count) bytes")


        try await ensureSpeechDetected(audioData, context: "transcribe")

        let languageConfig = resolveLanguageConfig(explicitLanguage: language)
        var config: [String: Any] = ["mode": "transcribe"]
        if !languageConfig.hints.isEmpty {
            config["language_hints"] = languageConfig.hints
        }
        let response = try await proxyTranscribe(audioData: audioData, config: config)
        let text = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw TranscriptionError.emptyTranscription }

        return text
    }

    /// Transcribe meeting audio with speaker diarization
    func transcribeMeeting(audioData: Data) async throws -> String {
        Log.transcription.info("transcribeMeeting: BEGIN, audioData size = \(audioData.count) bytes")


        try await ensureSpeechDetected(audioData, context: "transcribeMeeting")

        let languageConfig = resolveLanguageConfig()
        var config: [String: Any] = [
            "mode": "transcribe",
            "enable_speaker_diarization": true
        ]
        if !languageConfig.hints.isEmpty {
            config["language_hints"] = languageConfig.hints
        }
        let response = try await proxyTranscribe(audioData: audioData, config: config)
        let text = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw TranscriptionError.emptyTranscription }

        return text
    }

    /// Transcribe and translate using the configured language pair from settings
    func translateAndTranscribe(audioData: Data) async throws -> String {
        let langA = SettingsStorage.shared.translationLanguageA
        let langB = SettingsStorage.shared.translationLanguageB
        return try await translateAndTranscribe(audioData: audioData, languageA: langA, languageB: langB)
    }

    /// Transcribe and translate to a specific target language (legacy, pairs with stored Language A)
    func translateAndTranscribe(audioData: Data, targetLanguage: String) async throws -> String {
        let langA = SettingsStorage.shared.translationLanguageA
        return try await translateAndTranscribe(audioData: audioData, languageA: langA, languageB: targetLanguage)
    }

    private func translateAndTranscribe(audioData: Data, languageA: String, languageB: String) async throws -> String {
        Log.transcription.info("translateAndTranscribe: BEGIN, audioData size = \(audioData.count) bytes, pair = \(languageA) <-> \(languageB)")

        try await ensureSpeechDetected(audioData, context: "translateAndTranscribe")

        let langA = languageA
        let langB = languageB

        let languageConfig = resolveLanguageConfig(forcedLanguageHints: [langA, langB])
        var config: [String: Any] = [
            "mode": "translate",
            "translation": [
                "type": "two_way",
                "language_a": langA,
                "language_b": langB
            ]
        ]
        if !languageConfig.hints.isEmpty {
            config["language_hints"] = languageConfig.hints
        }
        let response = try await proxyTranscribe(audioData: audioData, config: config)
        let text = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw TranscriptionError.emptyTranscription }
        return text
    }

    // MARK: - Proxy Transcription (single POST /api/v1/transcriptions)

    private func proxyTranscribe(audioData: Data, config: [String: Any]) async throws -> ProxyTranscribeResponse {
        guard let url = URL(string: proxyTranscriptionsURL) else {
            throw TranscriptionError.invalidURL
        }

        let boundary = UUID().uuidString
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        await AuthService.shared.authenticatedRequest(&request)

        let configData = try JSONSerialization.data(withJSONObject: config)
        let configString = String(data: configData, encoding: .utf8) ?? "{}"

        let (filename, contentType) = detectAudioFormat(audioData)
        Log.transcription.info("proxyTranscribe: audio format=\(contentType), config=\(configString)")

        // Build multipart body: audio + config
        var body = Data()
        // Audio part
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"audio\"; filename=\"\(filename)\"\r\n".utf8))
        body.append(Data("Content-Type: \(contentType)\r\n\r\n".utf8))
        body.append(audioData)
        body.append(Data("\r\n".utf8))
        // Config part
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"config\"\r\n".utf8))
        body.append(Data("Content-Type: text/plain\r\n\r\n".utf8))
        body.append(Data(configString.utf8))
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        request.httpBody = body

        var (data, httpResponse) = try await performRequest(request, label: "proxyTranscribe")

        Log.transcription.info("proxyTranscribe: HTTP status = \(httpResponse.statusCode)")

        // 401 retry: refresh token and retry once
        if httpResponse.statusCode == 401 {
            Log.transcription.info("proxyTranscribe: 401 — refreshing token and retrying")
            try await AuthService.shared.refreshTokens()
            await AuthService.shared.authenticatedRequest(&request)
            (data, httpResponse) = try await performRequest(request, label: "proxyTranscribe(retry)")
        }

        // 402: usage limit exceeded
        if httpResponse.statusCode == 402 {
            Log.transcription.warning("proxyTranscribe: 402 — usage limit exceeded")
            Task { await UsageService.shared.refresh() }
            if let body = try? JSONDecoder().decode(UsageLimitErrorResponse.self, from: data) {
                throw TranscriptionError.usageLimitExceeded(
                    usedHours: body.usedHours, limitHours: body.limitHours
                )
            }
            throw TranscriptionError.usageLimitExceeded(usedHours: 0, limitHours: 0)
        }

        guard (200 ... 299).contains(httpResponse.statusCode) else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            Log.transcription.error("proxyTranscribe: Error - \(errorBody)")
            throw TranscriptionError.apiError("Proxy transcription failed (\(httpResponse.statusCode)): \(errorBody)")
        }

        return try JSONDecoder().decode(ProxyTranscribeResponse.self, from: data)
    }

    // MARK: - Speech Pre-check

    private func ensureSpeechDetected(_ audioData: Data, context: String) async throws {
        guard audioData.count <= maxAudioBytesForSpeechPrecheck else {
            Log.transcription.info(
                "\(context): skipping speech pre-check for large audio (\(audioData.count) bytes)"
            )
            return
        }

        let hasSpeech = await AudioSpeechDetector.hasSpeech(in: audioData)
        guard hasSpeech else {
            if strictSpeechPrecheck {
                Log.transcription.info("\(context): no speech detected, skipping cloud request")
                throw TranscriptionError.emptyTranscription
            }

            Log.transcription.info("\(context): no speech confidently detected, continuing with cloud")
            return
        }
    }

    // MARK: - Audio Format Detection

    /// Detects audio format from data header and returns appropriate filename and content type
    private func detectAudioFormat(_ data: Data) -> (filename: String, contentType: String) {
        guard data.count >= 12 else {
            return ("recording.wav", "audio/wav")
        }

        let bytes = [UInt8](data.prefix(12))

        // Check for WAV (RIFF....WAVE)
        if bytes[0] == 0x52, bytes[1] == 0x49, bytes[2] == 0x46, bytes[3] == 0x46, // "RIFF"
           bytes[8] == 0x57, bytes[9] == 0x41, bytes[10] == 0x56, bytes[11] == 0x45
        { // "WAVE"
            return ("recording.wav", "audio/wav")
        }

        // Check for M4A/AAC (ftyp box)
        if bytes[4] == 0x66, bytes[5] == 0x74, bytes[6] == 0x79, bytes[7] == 0x70 { // "ftyp"
            return ("recording.m4a", "audio/mp4")
        }

        // Check for MP3 (ID3 tag or sync word)
        if (bytes[0] == 0x49 && bytes[1] == 0x44 && bytes[2] == 0x33) || // "ID3"
            (bytes[0] == 0xFF && (bytes[1] & 0xE0) == 0xE0)
        { // MP3 sync
            return ("recording.mp3", "audio/mpeg")
        }

        // Check for FLAC
        if bytes[0] == 0x66, bytes[1] == 0x4C, bytes[2] == 0x61, bytes[3] == 0x43 { // "fLaC"
            return ("recording.flac", "audio/flac")
        }

        // Check for OGG
        if bytes[0] == 0x4F, bytes[1] == 0x67, bytes[2] == 0x67, bytes[3] == 0x53 { // "OggS"
            return ("recording.ogg", "audio/ogg")
        }

        // Default to WAV
        return ("recording.wav", "audio/wav")
    }

    // MARK: - Language Config

    private func resolveLanguageConfig(
        explicitLanguage: String? = nil,
        forcedLanguageHints: [String]? = nil
    ) -> (hints: [String], strict: Bool) {
        if let forcedLanguageHints {
            let hints = forcedLanguageHints.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            return (hints, !hints.isEmpty)
        }

        if let explicitLanguage {
            let trimmed = explicitLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return ([trimmed], true)
            }
        }

        let hints = SettingsStorage.shared.favoriteLanguages
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        return (hints, !hints.isEmpty)
    }

    // MARK: - HTTP Debug Wrapper

    private func performRequest(_ request: URLRequest, label: String) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw TranscriptionError.invalidResponse
        }

        return (data, httpResponse)
    }

    // MARK: - Test Connection

    func testConnection() async throws -> Bool {
        let proxyBase = SettingsStorage.shared.proxyBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let modelsURL = "\(proxyBase)/api/v1/models"

        guard let url = URL(string: modelsURL) else {
            throw TranscriptionError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        await AuthService.shared.authenticatedRequest(&request)

        let (data, httpResponse) = try await performRequest(request, label: "testConnection")

        if httpResponse.statusCode == 200 {
            return true
        } else if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
            let errorBody = String(data: data, encoding: .utf8) ?? "Invalid token"
            throw TranscriptionError.apiError(errorBody)
        } else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw TranscriptionError.apiError("Status \(httpResponse.statusCode): \(errorBody)")
        }
    }
}

private enum AudioSpeechDetector {
    private static let frameSize = 320 // 20 ms at 16 kHz
    private static let minSpeechDurationSeconds: Double = 0.18
    private static let minRmsThreshold: Float = 0.0015
    private static let dynamicThresholdMultiplier: Float = 1.8
    private static let minPeakThreshold: Float = 0.015

    static func hasSpeech(in audioData: Data) async -> Bool {
        await Task.detached(priority: .userInitiated) {
            do {
                let samples = try AudioConverter.convertToWhisperFormat(audioData: audioData)
                return detectSpeech(samples: samples)
            } catch {
                // Fallback to cloud transcription when local analysis fails.
                NSLog("[Transcription] Speech pre-check failed: \(error.localizedDescription)")
                return true
            }
        }.value
    }

    private static func detectSpeech(samples: [Float]) -> Bool {
        guard !samples.isEmpty else { return false }

        let frameMetrics = buildFrameMetrics(samples: samples)
        guard !frameMetrics.rmsValues.isEmpty else { return false }

        let noiseFloor = percentile20(values: frameMetrics.rmsValues)
        let rmsThreshold = max(minRmsThreshold, noiseFloor * dynamicThresholdMultiplier)
        let peakThreshold = max(minPeakThreshold, rmsThreshold * 2.0)

        let minSpeechFrames = max(
            1,
            Int(
                ceil(
                    (minSpeechDurationSeconds * AudioConverter.whisperSampleRate) / Double(frameSize)
                )
            )
        )
        let minConsecutiveFrames = max(3, minSpeechFrames / 2)

        var voicedFrames = 0
        var longestRun = 0
        var currentRun = 0

        for index in frameMetrics.rmsValues.indices {
            let isVoiced =
                frameMetrics.rmsValues[index] >= rmsThreshold &&
                frameMetrics.peakValues[index] >= peakThreshold

            if isVoiced {
                voicedFrames += 1
                currentRun += 1
                longestRun = max(longestRun, currentRun)
            } else {
                currentRun = 0
            }
        }

        return voicedFrames >= minSpeechFrames && longestRun >= minConsecutiveFrames
    }

    private static func buildFrameMetrics(samples: [Float]) -> (rmsValues: [Float], peakValues: [Float]) {
        var rmsValues: [Float] = []
        var peakValues: [Float] = []

        rmsValues.reserveCapacity((samples.count / frameSize) + 1)
        peakValues.reserveCapacity((samples.count / frameSize) + 1)

        var frameStart = 0
        while frameStart < samples.count {
            let frameEnd = min(frameStart + frameSize, samples.count)
            let count = frameEnd - frameStart
            if count < frameSize / 2 { break }

            var sumSquares: Float = 0
            var peak: Float = 0

            for index in frameStart..<frameEnd {
                let sample = samples[index]
                let amplitude = abs(sample)
                sumSquares += sample * sample
                peak = max(peak, amplitude)
            }

            let rms = sqrt(sumSquares / Float(count))
            rmsValues.append(rms)
            peakValues.append(peak)

            frameStart += frameSize
        }

        return (rmsValues, peakValues)
    }

    private static func percentile20(values: [Float]) -> Float {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let index = min(sorted.count - 1, Int(Double(sorted.count) * 0.2))
        return sorted[index]
    }
}

// MARK: - Response Models

// Proxy response: POST /api/v1/transcriptions returns { text, tokens }
private struct ProxyTranscribeResponse: Decodable {
    let text: String
    let tokens: [ProxyTranscribeToken]
}

private struct ProxyTranscribeToken: Decodable {
    let text: String
    let start_ms: Int
    let end_ms: Int
    let confidence: Double
    let speaker: String?
    let language: String?
    let translation_status: String?
    let source_language: String?
}

