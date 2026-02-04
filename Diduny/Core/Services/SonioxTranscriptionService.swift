import Foundation
import os

final class SonioxTranscriptionService: TranscriptionServiceProtocol {
    var apiKey: String?

    private let baseURL = "https://api.soniox.com/v1"
    private let defaultModel = "stt-async-preview"
    private let translationModel = "stt-async-v3"
    private let pollingInterval: TimeInterval = 1.0
    private let maxPollingAttempts = 60 // 60 seconds max wait

    // MARK: - Voice Note Processing Context

    // swiftlint:disable line_length
    private let voiceNoteContext = """
        role: Voice note processing assistant
        input: Raw Ukrainian speech transcript

        tasks[3]{id,name,actions}:
          1,Clean text,"remove fillers (е-е-е, ну, типу, як би), fix recognition errors, add punctuation"
          2,Detect type,determine if work note or brainstorm
          3,Format output,structure based on detected type

        processing_rules[2]{type,rules}:
          work_note,"extract key decisions, pull action items (who/what/when if present), group by topics if multiple"
          brainstorm,"keep all ideas even raw ones, group similar thoughts, never discard unfinished ideas"

        output_format:
          style: concise - no fluff
          headers: only when clear topic separation exists
          lists: bullets for lists
          dash: short (-) only - never long dash (—)

        restrictions[5]:
          never use long dash (—) - only short (-)
          never add your own ideas or suggestions
          never rephrase beyond recognition - keep my style
          never write preambles like "here are your notes"
          keep English tech terms as-is in Ukrainian text

        language: Ukrainian
        """
    // swiftlint:enable line_length

    // Protocol conformance method
    func transcribe(audioData: Data) async throws -> String {
        try await transcribe(audioData: audioData, language: nil)
    }

    func transcribe(audioData: Data, language: String?) async throws -> String {
        Log.transcription.info("transcribe: BEGIN, audioData size = \(audioData.count) bytes")

        guard let apiKey, !apiKey.isEmpty else {
            Log.transcription.error("transcribe: No API key!")
            throw TranscriptionError.noAPIKey
        }

        // Step 1: Upload the audio file
        Log.transcription.info("Step 1: Uploading audio file...")
        let fileId = try await uploadFile(audioData: audioData, apiKey: apiKey)
        Log.transcription.info("File uploaded, fileId = \(fileId)")

        // Step 2: Create transcription job with voice note context
        Log.transcription.info("Step 2: Creating transcription job with context...")
        let transcriptionId = try await createTranscription(
            fileId: fileId,
            language: language,
            context: voiceNoteContext,
            apiKey: apiKey
        )
        Log.transcription.info("Transcription created, id = \(transcriptionId)")

        // Step 3: Poll for completion
        Log.transcription.info("Step 3: Polling for completion...")
        try await waitForCompletion(transcriptionId: transcriptionId, apiKey: apiKey)
        Log.transcription.info("Transcription completed")

        // Step 4: Get the transcript text
        Log.transcription.info("Step 4: Retrieving transcript...")
        let text = try await getTranscript(transcriptionId: transcriptionId, apiKey: apiKey)
        Log.transcription.info("Transcript retrieved: \(text.prefix(50))...")

        return text
    }

    /// Transcribe meeting audio without voice note processing context
    func transcribeMeeting(audioData: Data) async throws -> String {
        Log.transcription.info("transcribeMeeting: BEGIN, audioData size = \(audioData.count) bytes")

        guard let apiKey, !apiKey.isEmpty else {
            Log.transcription.error("transcribeMeeting: No API key!")
            throw TranscriptionError.noAPIKey
        }

        // Step 1: Upload the audio file
        Log.transcription.info("Step 1: Uploading audio file...")
        let fileId = try await uploadFile(audioData: audioData, apiKey: apiKey)
        Log.transcription.info("File uploaded, fileId = \(fileId)")

        // Step 2: Create transcription job WITHOUT context (plain transcription for meetings)
        Log.transcription.info("Step 2: Creating transcription job (no context)...")
        let transcriptionId = try await createTranscription(
            fileId: fileId,
            language: nil,
            context: nil,
            apiKey: apiKey
        )
        Log.transcription.info("Transcription created, id = \(transcriptionId)")

        // Step 3: Poll for completion
        Log.transcription.info("Step 3: Polling for completion...")
        try await waitForCompletion(transcriptionId: transcriptionId, apiKey: apiKey)
        Log.transcription.info("Transcription completed")

        // Step 4: Get the transcript text
        Log.transcription.info("Step 4: Retrieving transcript...")
        let text = try await getTranscript(transcriptionId: transcriptionId, apiKey: apiKey)
        Log.transcription.info("Transcript retrieved: \(text.prefix(50))...")

        return text
    }

    /// Transcribe and translate between English and Ukrainian (auto-detects language)
    func translateAndTranscribe(audioData: Data) async throws -> String {
        Log.transcription.info("translateAndTranscribe: BEGIN, audioData size = \(audioData.count) bytes")

        guard let apiKey, !apiKey.isEmpty else {
            Log.transcription.error("translateAndTranscribe: No API key!")
            throw TranscriptionError.noAPIKey
        }

        // Step 1: Upload the audio file
        Log.transcription.info("Step 1: Uploading audio file...")
        let fileId = try await uploadFile(audioData: audioData, apiKey: apiKey)
        Log.transcription.info("File uploaded, fileId = \(fileId)")

        // Step 2: Create transcription job with two-way translation
        Log.transcription.info("Step 2: Creating transcription with translation...")
        let transcriptionId = try await createTranscriptionWithTranslation(fileId: fileId, apiKey: apiKey)
        Log.transcription.info("Transcription created, id = \(transcriptionId)")

        // Step 3: Poll for completion
        Log.transcription.info("Step 3: Polling for completion...")
        try await waitForCompletion(transcriptionId: transcriptionId, apiKey: apiKey)
        Log.transcription.info("Transcription completed")

        // Step 4: Get the translated transcript text
        Log.transcription.info("Step 4: Retrieving translated transcript...")
        let text = try await getTranslatedTranscript(transcriptionId: transcriptionId, apiKey: apiKey)
        Log.transcription.info("Translated transcript retrieved: \(text.prefix(50))...")

        return text
    }

    // MARK: - Step 1: Upload File

    private func uploadFile(audioData: Data, apiKey: String) async throws -> String {
        guard let url = URL(string: "\(baseURL)/files") else {
            throw TranscriptionError.invalidURL
        }

        let boundary = UUID().uuidString
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        // Build multipart body
        var body = Data()
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"recording.wav\"\r\n".utf8))
        body.append(Data("Content-Type: audio/wav\r\n\r\n".utf8))
        body.append(audioData)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw TranscriptionError.invalidResponse
        }

        Log.transcription.info("uploadFile: HTTP status = \(httpResponse.statusCode)")

        guard httpResponse.statusCode == 201 || httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            Log.transcription.error("uploadFile: Error - \(errorBody)")
            throw TranscriptionError.apiError("Upload failed: \(errorBody)")
        }

        let uploadResponse = try JSONDecoder().decode(FileUploadResponse.self, from: data)
        return uploadResponse.id
    }

    // MARK: - Step 2: Create Transcription

    private func createTranscription(
        fileId: String,
        language: String?,
        context: String?,
        apiKey: String
    ) async throws -> String {
        guard let url = URL(string: "\(baseURL)/transcriptions") else {
            throw TranscriptionError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var payload: [String: Any] = [
            "file_id": fileId,
            "model": defaultModel
        ]

        if let lang = language {
            payload["language_hints"] = [lang]
        }

        if let context {
            payload["context"] = context
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw TranscriptionError.invalidResponse
        }

        Log.transcription.info("createTranscription: HTTP status = \(httpResponse.statusCode)")

        guard httpResponse.statusCode == 201 || httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            Log.transcription.error("createTranscription: Error - \(errorBody)")
            throw TranscriptionError.apiError("Create transcription failed: \(errorBody)")
        }

        let transcriptionResponse = try JSONDecoder().decode(TranscriptionResponse.self, from: data)
        return transcriptionResponse.id
    }

    // MARK: - Create Transcription with Translation (EN <-> UK)

    private func createTranscriptionWithTranslation(fileId: String, apiKey: String) async throws -> String {
        guard let url = URL(string: "\(baseURL)/transcriptions") else {
            throw TranscriptionError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Two-way translation: English <-> Ukrainian with voice note context
        let payload: [String: Any] = [
            "file_id": fileId,
            "model": translationModel,
            "language_hints": ["en", "uk"],
            "context": voiceNoteContext,
            "translation": [
                "type": "two_way",
                "language_a": "en",
                "language_b": "uk"
            ]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw TranscriptionError.invalidResponse
        }

        Log.transcription.info("createTranscriptionWithTranslation: HTTP status = \(httpResponse.statusCode)")

        guard httpResponse.statusCode == 201 || httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            Log.transcription.error("createTranscriptionWithTranslation: Error - \(errorBody)")
            throw TranscriptionError.apiError("Create translation failed: \(errorBody)")
        }

        let transcriptionResponse = try JSONDecoder().decode(TranscriptionResponse.self, from: data)
        return transcriptionResponse.id
    }

    // MARK: - Step 3: Poll for Completion

    private func waitForCompletion(transcriptionId: String, apiKey: String) async throws {
        guard let url = URL(string: "\(baseURL)/transcriptions/\(transcriptionId)") else {
            throw TranscriptionError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        for attempt in 1 ... maxPollingAttempts {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200
            else {
                let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
                Log.transcription.error("Poll error: \(errorBody)")
                throw TranscriptionError.invalidResponse
            }

            let statusResponse = try JSONDecoder().decode(TranscriptionStatusResponse.self, from: data)
            Log.transcription.info("Poll attempt \(attempt): status = \(statusResponse.status)")

            switch statusResponse.status {
            case "completed":
                return
            case "error":
                let errorMsg = statusResponse.error_message ?? "Unknown error"
                let errorType = statusResponse.error_type ?? "unknown"
                Log.transcription.error("Transcription failed: \(errorType) - \(errorMsg)")
                throw TranscriptionError.apiError("Transcription failed: \(errorMsg)")
            case "queued", "processing":
                try await Task.sleep(nanoseconds: UInt64(pollingInterval * 1_000_000_000))
            default:
                try await Task.sleep(nanoseconds: UInt64(pollingInterval * 1_000_000_000))
            }
        }

        throw TranscriptionError.apiError("Transcription timed out after \(maxPollingAttempts) seconds")
    }

    // MARK: - Step 4: Get Transcript

    private func getTranscript(transcriptionId: String, apiKey: String) async throws -> String {
        guard let url = URL(string: "\(baseURL)/transcriptions/\(transcriptionId)/transcript") else {
            throw TranscriptionError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw TranscriptionError.invalidResponse
        }

        Log.transcription.info("getTranscript: HTTP status = \(httpResponse.statusCode)")

        guard httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            Log.transcription.error("getTranscript: Error - \(errorBody)")
            throw TranscriptionError.apiError("Get transcript failed: \(errorBody)")
        }

        let transcriptResponse = try JSONDecoder().decode(TranscriptResponse.self, from: data)

        guard !transcriptResponse.text.isEmpty else {
            throw TranscriptionError.emptyTranscription
        }

        return transcriptResponse.text
    }

    // MARK: - Get Translated Transcript

    private func getTranslatedTranscript(transcriptionId: String, apiKey: String) async throws -> String {
        guard let url = URL(string: "\(baseURL)/transcriptions/\(transcriptionId)/transcript") else {
            throw TranscriptionError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw TranscriptionError.invalidResponse
        }

        Log.transcription.info("getTranslatedTranscript: HTTP status = \(httpResponse.statusCode)")

        guard httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            Log.transcription.error("getTranslatedTranscript: Error - \(errorBody)")
            throw TranscriptionError.apiError("Get translated transcript failed: \(errorBody)")
        }

        let transcriptResponse = try JSONDecoder().decode(TranslatedTranscriptResponse.self, from: data)

        // Filter to only get translated tokens and concatenate their text
        let translatedTokens = transcriptResponse.tokens.filter { $0.translation_status == "translation" }

        if translatedTokens.isEmpty {
            // If no translated tokens, return original text
            Log.transcription.info("No translated tokens found, returning original text")
            guard !transcriptResponse.text.isEmpty else {
                throw TranscriptionError.emptyTranscription
            }
            return transcriptResponse.text
        }

        let translatedText = translatedTokens.map(\.text).joined()
        Log.transcription.info("Translated text extracted: \(translatedText.prefix(50))...")

        guard !translatedText.isEmpty else {
            throw TranscriptionError.emptyTranscription
        }

        return translatedText
    }

    // MARK: - Test Connection

    func testConnection() async throws -> Bool {
        guard let apiKey, !apiKey.isEmpty else {
            throw TranscriptionError.noAPIKey
        }

        // Use the models endpoint to verify API key works
        guard let url = URL(string: "\(baseURL)/models") else {
            throw TranscriptionError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            return false
        }

        // 200 = success, 401/403 = bad API key
        if httpResponse.statusCode == 200 {
            return true
        } else if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
            let errorBody = String(data: data, encoding: .utf8) ?? "Invalid API key"
            throw TranscriptionError.apiError(errorBody)
        } else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw TranscriptionError.apiError("Status \(httpResponse.statusCode): \(errorBody)")
        }
    }
}

// MARK: - Response Models

private struct FileUploadResponse: Decodable {
    let id: String
    let filename: String
    let size: Int
    let created_at: String
    let client_reference_id: String?
}

private struct TranscriptionResponse: Decodable {
    let id: String
    let status: String
    let model: String
    let filename: String
    let error_message: String?
}

private struct TranscriptionStatusResponse: Decodable {
    let id: String
    let status: String
    let error_message: String?
    let error_type: String?
}

private struct TranscriptResponse: Decodable {
    let id: String
    let text: String
    let tokens: [TranscriptToken]
}

private struct TranscriptToken: Decodable {
    let text: String
    let start_ms: Int
    let end_ms: Int
    let confidence: Double
    let speaker: String?
    let language: String?
}

private struct TranslatedTranscriptResponse: Decodable {
    let id: String
    let text: String
    let tokens: [TranslatedTranscriptToken]
}

private struct TranslatedTranscriptToken: Decodable {
    let text: String
    let start_ms: Int?
    let end_ms: Int?
    let confidence: Double?
    let speaker: String?
    let language: String?
    let translation_status: String?
    let source_language: String?
}
