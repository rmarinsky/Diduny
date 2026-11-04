import Foundation

struct ElevenLabsBatchResult: Equatable {
    let transcript: GeneratedTranscript
    /// Provider-side id; enqueue its delete after the transcript is saved locally.
    let transcriptionID: String?
    /// Normalised to ISO-639-1 when the provider returns ISO-639-3 (`eng` → `en`).
    let languageCode: String?
}

/// `POST /v1/speech-to-text` with the user's key. One automatic retry on 429, none on 4xx auth/quota errors.
final class ElevenLabsBatchService: @unchecked Sendable {
    static let retryDelaySeconds: TimeInterval = 2

    private let session: URLSession
    private let apiKey: () -> String?
    private let sleep: (TimeInterval) async -> Void
    private let baseURL: URL

    init(
        session: URLSession = .shared,
        baseURL: URL = ElevenLabsProvider.baseURL,
        apiKey: @escaping () -> String? = { ProviderKeyStore.shared.key(for: STTProviderID.elevenLabs) },
        sleep: @escaping (TimeInterval) async -> Void = { try? await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }
    ) {
        self.session = session
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.sleep = sleep
    }

    /// - Parameters:
    ///   - isPCM16kMono: the file is raw 16-bit LE PCM, 16 kHz mono (lower-latency fast path).
    ///   - languageCode: nil or "auto" lets ElevenLabs detect the language.
    ///   - diarize: speaker labels (meetings).
    func transcribe(
        audioURL: URL,
        isPCM16kMono: Bool = false,
        languageCode: String? = nil,
        diarize: Bool = false
    ) async throws -> ElevenLabsBatchResult {
        guard let key = apiKey() else { throw ElevenLabsError.invalidKey }

        var fields: [(String, String)] = [
            ("model_id", ElevenLabsProvider.batchModelID),
            ("timestamps_granularity", "word"),
            ("tag_audio_events", "false"),
        ]
        if let languageCode, languageCode.lowercased() != "auto" { fields.append(("language_code", languageCode)) }
        if diarize { fields.append(("diarize", "true")) }
        if isPCM16kMono { fields.append(("file_format", "pcm_s16le_16")) }

        let boundary = "diduny-\(UUID().uuidString)"
        let bodyURL = try Self.makeMultipartBody(fields: fields, audioURL: audioURL, boundary: boundary)
        defer { try? FileManager.default.removeItem(at: bodyURL) }

        var request = URLRequest(url: baseURL.appendingPathComponent("v1/speech-to-text"))
        request.httpMethod = "POST"
        request.setValue(key, forHTTPHeaderField: "xi-api-key")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 3600

        var (data, status) = try await send(request, bodyURL: bodyURL)
        if status == 429 {
            await sleep(Self.retryDelaySeconds)
            (data, status) = try await send(request, bodyURL: bodyURL)
        }
        guard (200 ..< 300).contains(status) else {
            throw ElevenLabsError.from(httpStatus: status, body: data)
        }
        return try Self.parse(data, diarize: diarize)
    }

    private func send(_ request: URLRequest, bodyURL: URL) async throws -> (Data, Int) {
        do {
            let (data, response) = try await session.upload(for: request, fromFile: bodyURL)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        } catch {
            throw ElevenLabsError.from(transportError: error)
        }
    }

    /// Writes the multipart body to a temp file so long recordings are not held in memory twice.
    static func makeMultipartBody(fields: [(String, String)], audioURL: URL, boundary: String) throws -> URL {
        let bodyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("diduny-elevenlabs-\(UUID().uuidString).multipart")
        guard FileManager.default.createFile(atPath: bodyURL.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            let output = try FileHandle(forWritingTo: bodyURL)
            defer { try? output.close() }
            for (name, value) in fields {
                try output.write(contentsOf: Data(
                    "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8
                ))
            }
            try output.write(contentsOf: Data(
                "--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(audioURL.lastPathComponent)\"\r\nContent-Type: application/octet-stream\r\n\r\n".utf8
            ))
            let input = try FileHandle(forReadingFrom: audioURL)
            defer { try? input.close() }
            while let chunk = try input.read(upToCount: 1_048_576), !chunk.isEmpty {
                try output.write(contentsOf: chunk)
            }
            try output.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
            return bodyURL
        } catch {
            try? FileManager.default.removeItem(at: bodyURL)
            throw error
        }
    }

    // MARK: - Response mapping

    private struct Response: Decodable {
        let languageCode: String?
        let text: String?
        let words: [Word]?
        let transcriptionID: String?
        let transcripts: [Response]?

        enum CodingKeys: String, CodingKey {
            case languageCode = "language_code", text, words, transcriptionID = "transcription_id", transcripts
        }
    }

    private struct Word: Decodable {
        let type: String?
        let token: JobTranscriptionToken

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            type = try container.decodeIfPresent(String.self, forKey: .type)
            token = try JobTranscriptionToken(from: decoder)
        }

        enum CodingKeys: String, CodingKey { case type }
    }

    static func parse(_ data: Data, diarize: Bool) throws -> ElevenLabsBatchResult {
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else {
            throw ElevenLabsError.invalidResponse
        }
        // Multichannel responses are merged in channel order; the app never requests multichannel.
        let parts = response.transcripts ?? [response]
        let text = parts.compactMap(\.text).joined(separator: "\n")
        let tokens = parts.flatMap { $0.words ?? [] }
            .filter { $0.type != "audio_event" }
            .map(\.token)
        let transcript = GeneratedTranscript(
            sourceText: text,
            tokens: tokens,
            providerSegments: nil,
            insertsSpacesBetweenTokens: false,
            preferSpeakerDiarization: diarize
        )
        let languageCode = response.languageCode ?? parts.first?.languageCode
        return ElevenLabsBatchResult(
            transcript: transcript,
            transcriptionID: response.transcriptionID ?? parts.first?.transcriptionID,
            languageCode: languageCode.map(normalizeLanguage)
        )
    }

    static func normalizeLanguage(_ code: String) -> String {
        let code = code.lowercased()
        guard code.count == 3 else { return code }
        return Locale.LanguageCode(code).identifier(.alpha2) ?? code
    }
}

/// `DELETE /v1/speech-to-text/transcripts/{id}`, driven by `RemoteDeletionQueue`.
struct ElevenLabsTranscriptDeleter: RemoteTranscriptDeleter {
    let session: URLSession
    let baseURL: URL

    init(session: URLSession = .shared, baseURL: URL = ElevenLabsProvider.baseURL) {
        self.session = session
        self.baseURL = baseURL
    }

    func deleteTranscript(remoteID: String, apiKey: String) async -> RemoteDeleteResult {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/speech-to-text/transcripts/\(remoteID)"))
        request.httpMethod = "DELETE"
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        guard let (_, response) = try? await session.data(for: request),
              let status = (response as? HTTPURLResponse)?.statusCode
        else { return .retryLater }
        switch status {
        case 200 ..< 300: return .deleted
        case 404: return .notFound
        case 401, 403: return .unauthorized
        default: return .retryLater
        }
    }
}
