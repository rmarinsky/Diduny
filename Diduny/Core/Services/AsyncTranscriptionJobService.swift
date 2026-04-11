import Foundation
import os

final class AsyncTranscriptionJobService {
    private var proxyBase: String {
        SettingsStorage.shared.proxyBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private let maxRetries = 3
    private let maxAudioBytesForSpeechPrecheck = 25 * 1024 * 1024
    private let longRunningSessionBodyThresholdBytes = 10 * 1024 * 1024
    private let strictSpeechPrecheck = false

    private lazy var longRunningSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 1200
        config.timeoutIntervalForResource = 7200
        return URLSession(configuration: config)
    }()

    // MARK: - Submit Job

    func submitJob(audioData: Data, config: [String: Any]) async throws -> JobSubmission {
        guard let url = URL(string: "\(proxyBase)/api/v1/jobs") else {
            throw TranscriptionError.invalidURL
        }

        try await ensureSpeechDetected(audioData, context: "submitJob")

        let preparedUpload = await prepareUploadPayload(audioData)
        let boundary = UUID().uuidString
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let configData = try JSONSerialization.data(withJSONObject: config)
        let configString = String(data: configData, encoding: .utf8) ?? "{}"

        var body = Data()
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(
            Data(
                "Content-Disposition: form-data; name=\"audio\"; filename=\"\(preparedUpload.filename)\"\r\n".utf8
            )
        )
        body.append(Data("Content-Type: \(preparedUpload.contentType)\r\n\r\n".utf8))
        body.append(preparedUpload.data)
        body.append(Data("\r\n".utf8))
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"config\"\r\n".utf8))
        body.append(Data("Content-Type: text/plain\r\n\r\n".utf8))
        body.append(Data(configString.utf8))
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        request.httpBody = body

        Log.transcription.info(
            "submitJob: audio format=\(preparedUpload.contentType), original=\(audioData.count) bytes, prepared=\(preparedUpload.data.count) bytes"
        )

        let (data, httpResponse) = try await performDataRequest(request)

        // 402: usage limit
        if httpResponse.statusCode == 402 {
            Log.transcription.warning("submitJob: 402 — usage limit exceeded")
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
            Log.transcription.error("submitJob: failed (\(httpResponse.statusCode)): \(errorBody)")
            throw TranscriptionError.apiError("Job submission failed (\(httpResponse.statusCode)): \(errorBody)")
        }

        let submission = try JSONDecoder().decode(JobSubmission.self, from: data)
        Log.transcription.info("submitJob: jobId=\(submission.jobId), status=\(submission.status)")
        return submission
    }

    // MARK: - Stream Job Result (SSE)

    func streamJobResult(jobId: String, onUpdate: @escaping (JobStatus) -> Void) async throws -> JobResult {
        guard let url = URL(string: "\(proxyBase)/api/v1/jobs/\(jobId)/events") else {
            throw TranscriptionError.invalidURL
        }

        var request = URLRequest(url: url)
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")

        let (bytes, httpResponse) = try await openEventStream(request)
        guard httpResponse.statusCode == 200 else {
            throw TranscriptionError.apiError("SSE connection failed (\(httpResponse.statusCode))")
        }

        var currentEvent = ""
        var currentData = ""

        for try await line in bytes.lines {
            if line.hasPrefix("event: ") {
                currentEvent = String(line.dropFirst(7))
            } else if line.hasPrefix("data: ") {
                currentData = String(line.dropFirst(6))
            } else if line.isEmpty && !currentEvent.isEmpty {
                switch currentEvent {
                case "status":
                    if let status = JobStatus(rawValue: currentData.trimmingCharacters(in: .whitespaces)) {
                        Log.transcription.info("SSE status: \(status.rawValue)")
                        onUpdate(status)
                    } else if let parsed = parseStatusFromJSON(currentData) {
                        Log.transcription.info("SSE status: \(parsed.rawValue)")
                        onUpdate(parsed)
                    }
                case "completed":
                    return try parseCompletedResult(currentData)
                case "error":
                    let message = parseErrorMessage(currentData)
                    throw TranscriptionError.apiError(message)
                default:
                    break
                }
                currentEvent = ""
                currentData = ""
            }
            // Lines starting with ":" are SSE comments (keep-alive), ignore them
        }

        throw TranscriptionError.apiError("SSE stream ended without result")
    }

    // MARK: - Poll Job Status (fallback)

    func getJobStatus(jobId: String) async throws -> JobStatusResponse {
        guard let url = URL(string: "\(proxyBase)/api/v1/jobs/\(jobId)") else {
            throw TranscriptionError.invalidURL
        }

        let request = URLRequest(url: url)
        let (data, httpResponse) = try await performDataRequest(request)
        guard (200 ... 299).contains(httpResponse.statusCode) else {
            throw TranscriptionError.apiError("Failed to get job status")
        }

        return try JSONDecoder().decode(JobStatusResponse.self, from: data)
    }

    // MARK: - Retry-aware transcription

    func transcribeMeetingWithRetry(
        audioData: Data,
        config: [String: Any],
        onUpdate: @escaping (JobStatus) -> Void
    ) async throws -> String {
        try await transcribeWithRetry(audioData: audioData, config: config, onUpdate: onUpdate)
    }

    func transcribeWithRetry(
        audioData: Data,
        config: [String: Any],
        onUpdate: @escaping (JobStatus) -> Void
    ) async throws -> String {
        try Task.checkCancellation()
        let submission = try await submitJob(audioData: audioData, config: config)

        var retries = 0

        while retries < self.maxRetries {
            try Task.checkCancellation()
            do {
                let result = try await streamJobResult(jobId: submission.jobId, onUpdate: onUpdate)
                return result.text
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                retries += 1
                Log.transcription.warning("SSE stream failed (attempt \(retries)/\(self.maxRetries)): \(error)")

                // Check if job finished while disconnected
                let status = try await getJobStatus(jobId: submission.jobId)
                if status.status == "completed", let result = status.result {
                    return result.text
                }
                if status.status == "error" {
                    throw TranscriptionError.apiError(status.error ?? "Transcription failed")
                }

                // Still in progress — backoff and retry SSE
                try Task.checkCancellation()
                try await Task.sleep(nanoseconds: UInt64(retries) * 2_000_000_000)
            }
        }

        throw TranscriptionError.apiError("Failed to get transcription result after \(self.maxRetries) retries")
    }

    // MARK: - Upload Preparation

    private struct PreparedUpload {
        let data: Data
        let filename: String
        let contentType: String
    }

    private func prepareUploadPayload(_ audioData: Data) async -> PreparedUpload {
        let optimizedData = await optimizeAudioForUpload(audioData)
        let (filename, contentType) = detectAudioFormat(optimizedData)
        return PreparedUpload(data: optimizedData, filename: filename, contentType: contentType)
    }

    /// Mirror the cloud sync path so jobs get the same smaller uploads and broader format support.
    private func optimizeAudioForUpload(_ audioData: Data) async -> Data {
        let startTime = ContinuousClock.now
        let downsampledData = await downsampleToSoniox(audioData)
        let compressedData = await AudioCompressionService.compressToFLAC(audioData: downsampledData)

        let elapsed = ContinuousClock.now - startTime
        let ratio = audioData.count > 0 ? Double(compressedData.count) / Double(audioData.count) * 100 : 100
        Log.transcription.info(
            "submitJob: optimized audio \(audioData.count) → \(compressedData.count) bytes (\(String(format: "%.1f%%", ratio))) in \(elapsed)"
        )

        return compressedData
    }

    private func downsampleToSoniox(_ audioData: Data) async -> Data {
        let tempDir = FileManager.default.temporaryDirectory
        let inputURL = tempDir.appendingPathComponent(UUID().uuidString + ".wav")
        let outputURL = tempDir.appendingPathComponent(UUID().uuidString + "_16k.wav")

        defer {
            try? FileManager.default.removeItem(at: inputURL)
            try? FileManager.default.removeItem(at: outputURL)
        }

        do {
            try audioData.write(to: inputURL)

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
            process.arguments = [
                "-f", "WAVE",
                "-d", "LEI16",
                "-c", "1",
                "-r", "16000",
                inputURL.path,
                outputURL.path,
            ]

            let errorPipe = Pipe()
            process.standardError = errorPipe

            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                process.terminationHandler = { proc in
                    if proc.terminationStatus == 0 {
                        continuation.resume()
                    } else {
                        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                        let msg = String(data: errorData, encoding: .utf8) ?? "exit \(proc.terminationStatus)"
                        continuation.resume(
                            throwing: NSError(
                                domain: "afconvert",
                                code: Int(proc.terminationStatus),
                                userInfo: [NSLocalizedDescriptionKey: msg]
                            )
                        )
                    }
                }
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                }
            }

            let downsampledData = try Data(contentsOf: outputURL)
            Log.transcription.info("submitJob: downsampled \(audioData.count) → \(downsampledData.count) bytes")
            return downsampledData
        } catch {
            Log.transcription.warning("submitJob: downsample failed, using original - \(error.localizedDescription)")
            return audioData
        }
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
                Log.transcription.info("\(context): no speech detected, skipping jobs request")
                throw TranscriptionError.emptyTranscription
            }

            Log.transcription.info("\(context): no speech confidently detected, continuing with jobs")
            return
        }
    }

    private func detectAudioFormat(_ data: Data) -> (filename: String, contentType: String) {
        guard data.count >= 12 else {
            return ("recording.wav", "audio/wav")
        }

        let bytes = [UInt8](data.prefix(12))

        if bytes[0] == 0x52, bytes[1] == 0x49, bytes[2] == 0x46, bytes[3] == 0x46,
           bytes[8] == 0x57, bytes[9] == 0x41, bytes[10] == 0x56, bytes[11] == 0x45
        {
            return ("recording.wav", "audio/wav")
        }

        if bytes[4] == 0x66, bytes[5] == 0x74, bytes[6] == 0x79, bytes[7] == 0x70 {
            return ("recording.m4a", "audio/mp4")
        }

        if (bytes[0] == 0x49 && bytes[1] == 0x44 && bytes[2] == 0x33) ||
            (bytes[0] == 0xFF && (bytes[1] & 0xE0) == 0xE0)
        {
            return ("recording.mp3", "audio/mpeg")
        }

        if bytes[0] == 0x66, bytes[1] == 0x4C, bytes[2] == 0x61, bytes[3] == 0x43 {
            return ("recording.flac", "audio/flac")
        }

        if bytes[0] == 0x4F, bytes[1] == 0x67, bytes[2] == 0x67, bytes[3] == 0x53 {
            return ("recording.ogg", "audio/ogg")
        }

        return ("recording.wav", "audio/wav")
    }

    // MARK: - HTTP Helpers

    private func session(for request: URLRequest) -> URLSession {
        let bodySize = request.httpBody?.count ?? 0
        return bodySize > longRunningSessionBodyThresholdBytes ? longRunningSession : URLSession.shared
    }

    private func performDataRequest(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await AuthService.shared.performWithAuth(request, session: session(for: request))
    }

    private func openEventStream(_ request: URLRequest) async throws -> (URLSession.AsyncBytes, HTTPURLResponse) {
        func performAttempt(
            for originalRequest: URLRequest,
            session: URLSession
        ) async throws -> (URLSession.AsyncBytes, HTTPURLResponse) {
            var authedRequest = originalRequest
            await AuthService.shared.authenticatedRequest(&authedRequest)

            let requestId = HTTPLogger.attachRequestId(&authedRequest)
            HTTPLogger.logRequest(authedRequest, requestId: requestId)

            let startTime = ContinuousClock.now
            let (bytes, response) = try await session.bytes(for: authedRequest)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw TranscriptionError.invalidResponse
            }

            HTTPLogger.logResponse(
                data: Data(),
                response: httpResponse,
                requestId: requestId,
                startTime: startTime
            )

            return (bytes, httpResponse)
        }

        let session = longRunningSession
        let (bytes, httpResponse) = try await performAttempt(for: request, session: session)
        if httpResponse.statusCode == 401 {
            Log.transcription.info("streamJobResult: 401 — refreshing token and retrying")
            try await AuthService.shared.refreshTokens()
            return try await performAttempt(for: request, session: session)
        }

        return (bytes, httpResponse)
    }

    // MARK: - SSE Parsing Helpers

    private func parseStatusFromJSON(_ data: String) -> JobStatus? {
        guard let jsonData = data.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let statusString = dict["status"] as? String
        else { return nil }
        return JobStatus(rawValue: statusString)
    }

    private func parseCompletedResult(_ data: String) throws -> JobResult {
        guard let jsonData = data.data(using: .utf8) else {
            throw TranscriptionError.invalidResponse
        }
        let result = try JSONDecoder().decode(JobTranscriptionResult.self, from: jsonData)
        return JobResult(text: result.text)
    }

    private func parseErrorMessage(_ data: String) -> String {
        if let jsonData = data.data(using: .utf8),
           let dict = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
           let message = dict["error"] as? String
        {
            return message
        }
        return data.trimmingCharacters(in: .whitespaces)
    }
}
