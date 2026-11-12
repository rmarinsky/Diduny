import Foundation
import os

struct BatchUploadDiagnostics: Equatable {
    let source: String
    let sourceDurationSeconds: TimeInterval?
    let originalBytes: Int
    let preparedBytes: Int
    let filename: String
    let contentType: String

    var message: String {
        [
            "source=\(source)",
            "sourceDuration=\(Self.formatDuration(sourceDurationSeconds))",
            "originalBytes=\(originalBytes)",
            "preparedBytes=\(preparedBytes)",
            "filename=\(filename)",
            "contentType=\(contentType)",
        ].joined(separator: " ")
    }

    private static func formatDuration(_ seconds: TimeInterval?) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return "unknown" }

        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let remainingSeconds = total % 60
        return String(format: "%d:%02d:%02d", hours, minutes, remainingSeconds)
    }
}

/// Reports the share of the request body sent, for upload progress.
private final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate {
    private let onProgress: (Double) -> Void

    init(_ onProgress: @escaping (Double) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        didSendBodyData _: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        guard totalBytesExpectedToSend > 0 else { return }
        onProgress(min(1, Double(totalBytesSent) / Double(totalBytesExpectedToSend)))
    }
}

/// The server no longer has the job (404/410): waiting longer cannot help.
struct JobGoneError: LocalizedError, Equatable {
    static let statusCodes: Set<Int> = [404, 410]
    let statusCode: Int

    var errorDescription: String? {
        String(localized: "The transcription server no longer has this job. Transcribe the recording again.")
    }
}

/// Waiting stopped while the job may still finish on the server: a retry resumes the same job.
enum JobWaitInterruptedError: LocalizedError, Equatable {
    case unreachable
    case timedOut

    var errorDescription: String? {
        switch self {
        case .unreachable: String(localized: "The transcription server could not be reached. Try again to pick up the same job.")
        case .timedOut: String(localized: "The transcription is taking too long. Try again to pick up the same job.")
        }
    }

    /// A network failure or an interrupted wait leaves the job alive; any other failure ends it.
    static func jobMayStillFinish(after error: Error) -> Bool {
        error is JobWaitInterruptedError || error is URLError
    }
}

final class AsyncTranscriptionJobService {
    private var proxyBase: String {
        SettingsStorage.shared.proxyBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private let maxJobWaitSeconds: TimeInterval = 7200
    private let maxAudioBytesForSpeechPrecheck = 25 * 1024 * 1024
    private let longRunningSessionBodyThresholdBytes = 10 * 1024 * 1024
    private let statusPollRetryCount = 3

    private lazy var longRunningSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 1200
        config.timeoutIntervalForResource = 7200
        return URLSession(configuration: config)
    }()

    // MARK: - Submit Job

    /// Submits an already prepared audio file without decoding or duplicating it in memory.
    func submitJob(
        audioFileURL: URL,
        config: [String: Any],
        source: String? = nil,
        sourceDurationSeconds: TimeInterval? = nil,
        onUploadProgress: ((Double) -> Void)? = nil
    ) async throws -> JobSubmission {
        guard let url = URL(string: "\(proxyBase)/api/v1/jobs") else {
            throw TranscriptionError.invalidURL
        }

        try await ensureSpeechDetected(at: audioFileURL, context: "submitJob")

        let uploadMetadata = Self.fileUploadMetadata(for: audioFileURL)
        let sourceSize = fileSize(at: audioFileURL)
        let diagnostics = BatchUploadDiagnostics(
            source: source ?? audioFileURL.lastPathComponent,
            sourceDurationSeconds: sourceDurationSeconds,
            originalBytes: sourceSize,
            preparedBytes: sourceSize,
            filename: uploadMetadata.filename,
            contentType: uploadMetadata.contentType
        )
        let multipart = try MultipartFormDataFile.create(
            audioURL: audioFileURL,
            filename: uploadMetadata.filename,
            contentType: uploadMetadata.contentType,
            config: config
        )
        defer { multipart.remove() }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(
            "multipart/form-data; boundary=\(multipart.boundary)",
            forHTTPHeaderField: "Content-Type"
        )
        request.setValue(String(multipart.contentLength), forHTTPHeaderField: "Content-Length")

        Log.transcription.info(
            "submitJob: file-backed audio upload, source=\(sourceSize) bytes, multipart=\(multipart.contentLength) bytes"
        )
        Log.transcription.notice("submitJob upload diagnostics: \(diagnostics.message, privacy: .public)")

        let (data, httpResponse) = try await AuthService.shared.performUploadWithAuth(
            request,
            bodyFileURL: multipart.fileURL,
            session: longRunningSession,
            delegate: onUploadProgress.map(UploadProgressDelegate.init)
        )
        return try decodeSubmissionResponse(data: data, httpResponse: httpResponse, diagnostics: diagnostics)
    }

    static func fileUploadMetadata(for audioFileURL: URL) -> (filename: String, contentType: String) {
        switch audioFileURL.pathExtension.lowercased() {
        case "flac":
            ("recording.flac", "audio/flac")
        case "mp3":
            ("recording.mp3", "audio/mpeg")
        case "wav":
            ("recording.wav", "audio/wav")
        case "ogg", "oga":
            ("recording.ogg", "audio/ogg")
        case "aac":
            ("recording.aac", "audio/aac")
        default:
            ("recording.m4a", "audio/mp4")
        }
    }

    // MARK: - Stream Job Result (SSE)

    private func streamJobResult(
        jobId: String,
        onProgressUpdate: @escaping (JobProgressUpdate) -> Void
    ) async throws -> JobResult {
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
            } else if line.isEmpty, !currentEvent.isEmpty {
                switch currentEvent {
                case "status":
                    if let status = JobStatus(rawValue: currentData.trimmingCharacters(in: .whitespaces)) {
                        Log.transcription.info("SSE status: \(status.rawValue)")
                        onProgressUpdate(JobProgressUpdate(status: status))
                    } else if let update = Self.progressUpdate(fromStatusPayload: currentData) {
                        Log.transcription.info("SSE status: \(update.status.rawValue)")
                        onProgressUpdate(update)
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
        if JobGoneError.statusCodes.contains(httpResponse.statusCode) {
            throw JobGoneError(statusCode: httpResponse.statusCode)
        }
        guard (200 ... 299).contains(httpResponse.statusCode) else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw TranscriptionError.apiError("Failed to get job status (\(httpResponse.statusCode)): \(errorBody)")
        }

        return try JSONDecoder().decode(JobStatusResponse.self, from: data)
    }

    // MARK: - Retry-aware transcription

    func transcribeFileDetailedWithRetry(
        audioFileURL: URL,
        config: [String: Any],
        source: String? = nil,
        sourceDurationSeconds: TimeInterval? = nil,
        onSubmitted: ((String) -> Void)? = nil,
        onUploadProgress: ((Double) -> Void)? = nil,
        onProgressUpdate: @escaping (JobProgressUpdate) -> Void
    ) async throws -> GeneratedTranscript {
        try Task.checkCancellation()
        let preferSpeakerDiarization = shouldPreferSpeakerDiarization(config: config)
        let submission = try await submitJob(
            audioFileURL: audioFileURL,
            config: config,
            source: source,
            sourceDurationSeconds: sourceDurationSeconds,
            onUploadProgress: onUploadProgress
        )
        onSubmitted?(submission.jobId)
        return try await waitForResult(
            submission: submission,
            preferSpeakerDiarization: preferSpeakerDiarization,
            onProgressUpdate: onProgressUpdate
        )
    }

    func resumeFileDetailed(
        jobID: String,
        config: [String: Any],
        onProgressUpdate: @escaping (JobProgressUpdate) -> Void
    ) async throws -> GeneratedTranscript {
        try await waitForResult(
            submission: JobSubmission(jobId: jobID, status: "processing", createdAt: ""),
            preferSpeakerDiarization: shouldPreferSpeakerDiarization(config: config),
            onProgressUpdate: onProgressUpdate
        )
    }

    private func waitForResult(
        submission: JobSubmission,
        preferSpeakerDiarization: Bool,
        onProgressUpdate: @escaping (JobProgressUpdate) -> Void
    ) async throws -> GeneratedTranscript {
        let jobId = submission.jobId
        return try await Self.waitLoop(
            deadline: Date().addingTimeInterval(maxJobWaitSeconds),
            stream: {
                try await self.streamJobResult(jobId: jobId, onProgressUpdate: onProgressUpdate)
                    .generatedTranscript(preferSpeakerDiarization: preferSpeakerDiarization)
            },
            status: { attempt in try await self.getJobStatusAfterDisconnect(jobId: jobId, sseAttempt: attempt) },
            transcript: { $0.generatedTranscript(preferSpeakerDiarization: preferSpeakerDiarization) },
            onProgressUpdate: onProgressUpdate
        )
    }

    /// Rounds in a row where neither the event stream nor the status poll answered before the job is given up.
    static let maxConsecutiveUnreachableRounds = 10

    /// Waits for a submitted job: the event stream first, the status endpoint when the stream drops.
    /// A job the server no longer knows (404/410) is final. After the deadline, which a Mac asleep
    /// for hours passes without a single round, the status is read once more before giving up.
    static func waitLoop(
        deadline: Date,
        now: () -> Date = Date.init,
        stream: () async throws -> GeneratedTranscript,
        status: (_ attempt: Int) async throws -> JobStatusResponse?,
        transcript: (JobTranscriptionResult) -> GeneratedTranscript,
        sleep: (TimeInterval) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) },
        onProgressUpdate: (JobProgressUpdate) -> Void
    ) async throws -> GeneratedTranscript {
        var sseFailures = 0
        var unreachableRounds = 0

        func finished(_ status: JobStatusResponse) throws -> GeneratedTranscript? {
            if status.status == "completed", let result = status.result { return transcript(result) }
            if status.status == "error" { throw TranscriptionError.apiError(status.error ?? "Transcription failed") }
            if let parsed = JobStatus(rawValue: status.status) {
                onProgressUpdate(JobProgressUpdate(status: parsed, progressPercent: status.progress))
            }
            return nil
        }

        while now() < deadline {
            try Task.checkCancellation()
            do {
                return try await stream()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                sseFailures += 1
                Log.transcription.warning("SSE stream failed (attempt \(sseFailures)): \(error)")

                // Check if job finished while disconnected
                if let current = try await status(sseFailures) {
                    unreachableRounds = 0
                    if let done = try finished(current) { return done }
                } else {
                    unreachableRounds += 1
                    if unreachableRounds >= maxConsecutiveUnreachableRounds {
                        throw JobWaitInterruptedError.unreachable
                    }
                }

                // Still in progress. SSE is best-effort; keep polling/retrying until
                // the server-side job reaches a terminal state or the long job timeout.
                try Task.checkCancellation()
                try await sleep(min(Double(max(sseFailures, 1)) * 2, 30))
            }
        }

        if let current = try await status(sseFailures + 1), let done = try finished(current) { return done }
        throw JobWaitInterruptedError.timedOut
    }

    private func getJobStatusAfterDisconnect(jobId: String, sseAttempt: Int) async throws -> JobStatusResponse? {
        var lastError: Error?
        let retryCount = statusPollRetryCount

        for attempt in 1 ... retryCount {
            try Task.checkCancellation()

            do {
                return try await getJobStatus(jobId: jobId)
            } catch is CancellationError {
                throw CancellationError()
            } catch let gone as JobGoneError {
                throw gone
            } catch {
                lastError = error
                Log.transcription.warning(
                    "Job status poll failed after SSE disconnect (sseAttempt=\(sseAttempt), pollAttempt=\(attempt)): \(error.localizedDescription)"
                )

                if attempt < retryCount {
                    let delaySeconds = min(Double(attempt), 3)
                    try await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
                }
            }
        }

        if let lastError {
            Log.transcription.warning(
                "Job status temporarily unavailable after \(retryCount) attempts; keeping async job alive: \(lastError.localizedDescription)"
            )
        }

        return nil
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
            Log.transcription.info("\(context): no speech detected, skipping jobs request")
            throw TranscriptionError.emptyTranscription
        }
    }

    private func ensureSpeechDetected(at audioFileURL: URL, context: String) async throws {
        let size = fileSize(at: audioFileURL)
        guard size <= maxAudioBytesForSpeechPrecheck else {
            Log.transcription.info(
                "\(context): skipping speech pre-check for large audio file (\(size) bytes)"
            )
            return
        }
        let data = try await Task.detached(priority: .utility) {
            try Data(contentsOf: audioFileURL)
        }.value
        try await ensureSpeechDetected(data, context: context)
    }

    private func fileSize(at url: URL) -> Int {
        let value = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        return value ?? 0
    }

    private func decodeSubmissionResponse(
        data: Data,
        httpResponse: HTTPURLResponse,
        diagnostics: BatchUploadDiagnostics? = nil
    ) throws -> JobSubmission {
        if httpResponse.statusCode == 402 {
            Log.transcription.warning("submitJob: 402 — usage limit exceeded")
            Task { await UsageService.shared.refresh() }
            if let body = try? JSONDecoder().decode(UsageLimitErrorResponse.self, from: data) {
                throw TranscriptionError.usageLimitExceeded(
                    usedHours: body.usedHours,
                    limitHours: body.limitHours
                )
            }
            throw TranscriptionError.usageLimitExceeded(usedHours: 0, limitHours: 0)
        }

        guard (200 ... 299).contains(httpResponse.statusCode) else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            if let diagnostics {
                Log.transcription.error(
                    "submitJob failed status=\(httpResponse.statusCode, privacy: .public) diagnostics=\(diagnostics.message, privacy: .public) body=\(errorBody, privacy: .public)"
                )
            } else {
                Log.transcription.error("submitJob: failed (\(httpResponse.statusCode)): \(errorBody)")
            }
            throw TranscriptionError.apiError(
                "Job submission failed (\(httpResponse.statusCode)): \(errorBody)"
            )
        }

        let submission = try JSONDecoder().decode(JobSubmission.self, from: data)
        Log.transcription.info("submitJob: jobId=\(submission.jobId), status=\(submission.status)")
        return submission
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

    static func progressUpdate(fromStatusPayload data: String) -> JobProgressUpdate? {
        guard let jsonData = data.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let statusString = dict["status"] as? String
        else { return nil }
        guard let status = JobStatus(rawValue: statusString) else { return nil }
        let progressPercent = (dict["progress"] as? NSNumber)?.intValue
        return JobProgressUpdate(status: status, progressPercent: progressPercent)
    }

    private func parseCompletedResult(_ data: String) throws -> JobResult {
        guard let jsonData = data.data(using: .utf8) else {
            throw TranscriptionError.invalidResponse
        }
        if let wrapped = try? JSONDecoder().decode(JobStatusResponse.self, from: jsonData),
           let result = wrapped.result
        {
            return JobResult(
                text: result.text,
                tokens: result.tokens,
                providerSegments: result.providerSegments,
                insertsSpacesBetweenTokens: result.insertsSpacesBetweenTokens
            )
        }
        let direct = try JSONDecoder().decode(JobTranscriptionResult.self, from: jsonData)
        return JobResult(
            text: direct.text,
            tokens: direct.tokens,
            providerSegments: direct.providerSegments,
            insertsSpacesBetweenTokens: direct.insertsSpacesBetweenTokens
        )
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

    private func shouldPreferSpeakerDiarization(config: [String: Any]) -> Bool {
        let value = config["enable_speaker_diarization"]
        if let bool = value as? Bool {
            return bool
        }
        if let number = value as? NSNumber {
            return number.boolValue
        }
        if let string = value as? String {
            switch string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "1", "true", "t", "yes", "y":
                return true
            default:
                return false
            }
        }
        return false
    }
}
