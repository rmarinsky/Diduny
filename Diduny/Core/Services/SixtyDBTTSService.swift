import AVFoundation
import Foundation

/// Text-to-speech via the 60db API (https://api.60db.ai).
///
/// Calls the 60db API directly with a user-supplied API key (Keychain),
/// outside the transcription proxy. Synthesizes LINEAR16 PCM, wraps it in a
/// WAV container, and plays it through `AVAudioPlayer`, mirroring the
/// ergonomics of `AudioPlaybackService`.
@Observable
@MainActor
final class SixtyDBTTSService: NSObject, SpeechSynthesisServiceProtocol {
    static let shared = SixtyDBTTSService()

    /// 60db documented default voice.
    static let defaultVoiceID = UUID(uuidString: "fbb75ed2-975a-40c7-9e06-38e30524a9a1")!
    static let defaultBaseURL = "https://api.60db.ai"
    /// 60db TTS accepts at most 50,000 characters per synthesis.
    static let maxTextLength = 50_000

    private static let apiKeyKeychainKey = "tts_60db_api_key"

    // MARK: - Observed State

    private(set) var speakingVersionId: UUID?
    private(set) var isSpeaking = false
    private(set) var isLoading = false
    private(set) var voices: [TTSVoice] = []
    private(set) var isLoadingVoices = false

    private var player: AVAudioPlayer?
    private let session: URLSession
    private let tokenStore: any AuthTokenStore
    private let baseURLOverride: String?

    // MARK: - Init

    init(
        session: URLSession = .shared,
        tokenStore: any AuthTokenStore = KeychainManager.shared,
        baseURL: String? = nil
    ) {
        self.session = session
        self.tokenStore = tokenStore
        self.baseURLOverride = baseURL
        super.init()
    }

    // MARK: - API Key (Keychain)

    var hasAPIKey: Bool { apiKey != nil }

    var apiKey: String? {
        let value = tokenStore.read(key: Self.apiKeyKeychainKey)
        return (value?.isEmpty == false) ? value : nil
    }

    /// Stores the API key. Passing `nil` or an empty string removes it.
    func saveAPIKey(_ value: String?) throws {
        guard let value, !value.isEmpty else {
            tokenStore.delete(key: Self.apiKeyKeychainKey)
            return
        }
        try tokenStore.save(key: Self.apiKeyKeychainKey, value: value)
    }

    // MARK: - Config (SettingsStorage)

    var selectedVoiceID: UUID {
        SettingsStorage.shared.ttsSelectedVoiceID
            .flatMap(UUID.init(uuidString:)) ?? Self.defaultVoiceID
    }

    var modelTier: TTSModelTier { SettingsStorage.shared.ttsModelTier }
    var speed: Double { SettingsStorage.shared.ttsSpeed }

    // MARK: - Speak

    /// Speaks `text` for the given transcript version. Tapping the active
    /// version again (while loading or speaking) stops playback.
    func toggleSpeak(versionId: UUID, text: String, languageCode: String? = nil) async throws {
        if speakingVersionId == versionId {
            stopSpeaking()
            return
        }

        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        stopSpeaking()
        guard apiKey != nil else { throw TTSError.noAPIKey }

        isLoading = true
        speakingVersionId = versionId
        Log.tts.info("Synthesizing speech for version \(versionId) (\(text.count) chars)")

        do {
            // `languageCode` is intentionally not forwarded: 60db auto-detects
            // language and its catalog (English + Indic) does not cover every
            // transcription language, so an explicit code could be rejected.
            let wavData = try await synthesizeWAV(text: text)
            guard speakingVersionId == versionId, isLoading else { return } // stopped while loading

            let audioPlayer = try AVAudioPlayer(data: wavData)
            audioPlayer.delegate = self
            audioPlayer.prepareToPlay()
            audioPlayer.play()

            player = audioPlayer
            isLoading = false
            isSpeaking = true
            Log.tts.info("Started speaking version \(versionId)")
        } catch {
            let wasActive = speakingVersionId == versionId
            stopSpeaking()
            if wasActive {
                Log.tts.error("TTS failed for version \(versionId): \(error.localizedDescription)")
                throw error
            }
        }
    }

    func stopSpeaking() {
        player?.stop()
        player = nil
        speakingVersionId = nil
        isSpeaking = false
        isLoading = false
    }

    // MARK: - Voices

    @discardableResult
    func fetchVoices() async throws -> [TTSVoice] {
        isLoadingVoices = true
        defer { isLoadingVoices = false }

        let path = "/voices?model=\(modelTier.rawValue)"
        let data = try await performRequest(path: path, method: "GET")

        let decoded: TTSVoicesResponse
        do {
            decoded = try JSONDecoder().decode(TTSVoicesResponse.self, from: data)
        } catch {
            Log.tts.error("Failed to decode voices response: \(error.localizedDescription)")
            throw TTSError.invalidResponse
        }

        guard decoded.success else {
            throw TTSError.apiError(status: 200, message: decoded.message)
        }

        voices = decoded.data
        Log.tts.info("Loaded \(decoded.data.count) voices (model=\(modelTier.rawValue))")
        return decoded.data
    }

    /// Returns `true` when the stored API key is accepted by 60db.
    func testConnection() async throws -> Bool {
        _ = try await performRequest(path: "/voices", method: "GET")
        return true
    }

    // MARK: - Private

    private func synthesizeWAV(text: String) async throws -> Data {
        let trimmed = text.count > Self.maxTextLength ? String(text.prefix(Self.maxTextLength)) : text
        if trimmed.count < text.count {
            Log.tts.warning("TTS text truncated from \(text.count) to \(Self.maxTextLength) characters")
        }

        let body: [String: Any] = [
            "text": trimmed,
            "voice_id": selectedVoiceID.uuidString,
            "audio_config": [
                "audio_encoding": "LINEAR16",
                "sample_rate_hertz": 24_000
            ],
            "speed": speed,
            "timestamp_type": "NONE"
        ]

        let data = try await performRequest(path: "/tts-synthesize", method: "POST", body: body)

        let decoded: TTSSynthesisResponse
        do {
            decoded = try JSONDecoder().decode(TTSSynthesisResponse.self, from: data)
        } catch {
            Log.tts.error("Failed to decode synthesis response: \(error.localizedDescription)")
            throw TTSError.invalidResponse
        }

        guard decoded.success, let pcm = Data(base64Encoded: decoded.audioBase64), !pcm.isEmpty else {
            throw TTSError.noAudioData
        }

        return WAVBuilder.wavData(fromPCM: pcm, sampleRate: decoded.sampleRate)
    }

    private func performRequest(path: String, method: String, body: [String: Any]? = nil) async throws -> Data {
        guard let key = apiKey else { throw TTSError.noAPIKey }
        let base = baseURLOverride ?? Self.defaultBaseURL
        guard let url = URL(string: base + path) else { throw TTSError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let (data, response) = try await Self.send(request, session: session)
        guard (200 ... 299).contains(response.statusCode) else {
            throw TTSError.apiError(status: response.statusCode, message: Self.errorMessage(from: data))
        }
        return data
    }

    nonisolated private static func send(
        _ sourceRequest: URLRequest,
        session: URLSession
    ) async throws -> (Data, HTTPURLResponse) {
        var request = sourceRequest
        let requestId = HTTPLogger.attachRequestId(&request)
        HTTPLogger.logRequest(request, requestId: requestId)
        let startTime = ContinuousClock.now
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw TTSError.invalidResponse
        }
        HTTPLogger.logResponse(data: data, response: httpResponse, requestId: requestId, startTime: startTime)
        return (data, httpResponse)
    }

    private static func errorMessage(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let message = object["message"] as? String { return message }
        if let error = object["error"] as? [String: Any], let message = error["message"] as? String {
            return message
        }
        return nil
    }
}

// MARK: - AVAudioPlayerDelegate

extension SixtyDBTTSService: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_: AVAudioPlayer, successfully _: Bool) {
        Task { @MainActor in
            player = nil
            speakingVersionId = nil
            isSpeaking = false
            isLoading = false
        }
    }
}
