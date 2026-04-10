import Foundation

// MARK: - Async Jobs API Models

struct JobSubmission: Decodable {
    let jobId: String
    let status: String
    let createdAt: String
}

struct JobStatusResponse: Decodable {
    let jobId: String
    let status: String
    let progress: Int?
    let createdAt: String
    let updatedAt: String
    let result: JobTranscriptionResult?
    let error: String?
}

struct JobTranscriptionResult: Decodable {
    let text: String
}

struct JobResult {
    let text: String
}

enum JobStatus: String {
    case queued, uploading, processing, finalizing, completed, error
}
