import Foundation
import os

final class AsyncTranscriptionJobService {
    private var proxyBase: String {
        SettingsStorage.shared.proxyBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private let maxRetries = 3

    // MARK: - Submit Job

    func submitJob(audioData: Data, config: [String: Any]) async throws -> JobSubmission {
        guard let url = URL(string: "\(proxyBase)/api/v1/jobs") else {
            throw TranscriptionError.invalidURL
        }

        let boundary = UUID().uuidString
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        await AuthService.shared.authenticatedRequest(&request)

        let configData = try JSONSerialization.data(withJSONObject: config)
        let configString = String(data: configData, encoding: .utf8) ?? "{}"

        var body = Data()
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"audio\"; filename=\"meeting.flac\"\r\n".utf8))
        body.append(Data("Content-Type: audio/flac\r\n\r\n".utf8))
        body.append(audioData)
        body.append(Data("\r\n".utf8))
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"config\"\r\n".utf8))
        body.append(Data("Content-Type: text/plain\r\n\r\n".utf8))
        body.append(Data(configString.utf8))
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        request.httpBody = body

        Log.transcription.info("submitJob: uploading \(audioData.count) bytes")

        var (data, response) = try await URLSession.shared.data(for: request)
        guard var httpResponse = response as? HTTPURLResponse else {
            throw TranscriptionError.invalidResponse
        }

        // 401 retry
        if httpResponse.statusCode == 401 {
            Log.transcription.info("submitJob: 401 — refreshing token and retrying")
            try await AuthService.shared.refreshTokens()
            await AuthService.shared.authenticatedRequest(&request)
            (data, response) = try await URLSession.shared.data(for: request)
            guard let retryResponse = response as? HTTPURLResponse else {
                throw TranscriptionError.invalidResponse
            }
            httpResponse = retryResponse
        }

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
        await AuthService.shared.authenticatedRequest(&request)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw TranscriptionError.apiError("SSE connection failed")
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

        var request = URLRequest(url: url)
        await AuthService.shared.authenticatedRequest(&request)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200 ... 299).contains(httpResponse.statusCode) else {
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
        let submission = try await submitJob(audioData: audioData, config: config)

        var retries = 0

        while retries < self.maxRetries {
            do {
                let result = try await streamJobResult(jobId: submission.jobId, onUpdate: onUpdate)
                return result.text
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
                try await Task.sleep(nanoseconds: UInt64(retries) * 2_000_000_000)
            }
        }

        throw TranscriptionError.apiError("Failed to get transcription result after \(self.self.maxRetries) retries")
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
