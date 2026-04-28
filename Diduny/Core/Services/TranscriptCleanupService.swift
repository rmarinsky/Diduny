import Foundation
import Network
import os

/// Calls the backend `POST /api/v1/transcriptions/clean` endpoint to apply
/// the full server-side cleanup pipeline (dedup, filler-word removal, formatting).
///
/// Falls back to `rawText` — silently, never throws — when:
/// - user has no stored auth session
/// - device has no network (NWPathMonitor)
/// - input is empty
/// - request times out or server returns an error
final class TranscriptCleanupService {
    static let shared = TranscriptCleanupService()

    // MARK: - Network Reachability

    private let monitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "ua.com.rmarinsky.diduny.cleanup-monitor")

    /// Starts as `true` so the first dictation on a newly-launched app is not
    /// blocked while NWPathMonitor fires its initial update.
    private(set) var isReachable: Bool = true

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            self?.isReachable = path.status == .satisfied
        }
        monitor.start(queue: monitorQueue)
    }

    // MARK: - Public API

    /// Cleans `rawText` via the backend.  Returns `rawText` unchanged on any failure.
    func clean(_ rawText: String, fillerWords: [String]) async -> String {
        guard !rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return rawText
        }
        guard AuthService.hasStoredSession else {
            Log.app.info("[Cleanup] No auth session — skipping server cleanup")
            return rawText
        }
        guard isReachable else {
            Log.app.info("[Cleanup] No network — skipping server cleanup")
            return rawText
        }

        let baseURL = SettingsStorage.shared.proxyBaseURL
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(baseURL)/api/v1/transcriptions/clean") else {
            Log.app.warning("[Cleanup] Invalid proxy URL — skipping")
            return rawText
        }

        var body: [String: Any] = ["text": rawText]
        if !fillerWords.isEmpty {
            body["fillerWords"] = fillerWords
        }

        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
            Log.app.warning("[Cleanup] JSON serialization failed — skipping")
            return rawText
        }

        var request = URLRequest(url: url, timeoutInterval: 3)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = bodyData
        await AuthService.shared.authenticatedRequest(&request)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let http = response as? HTTPURLResponse,
                  (200 ... 299).contains(http.statusCode) else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                Log.app.warning("[Cleanup] Server returned \(code) — using raw text")
                return rawText
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let cleaned = json["text"] as? String else {
                Log.app.warning("[Cleanup] Unexpected response shape — using raw text")
                return rawText
            }

            let applied = json["applied"] as? Bool ?? false
            Log.app.info("[Cleanup] Server cleanup applied=\(applied), chars \(rawText.count) → \(cleaned.count)")
            return cleaned

        } catch {
            Log.app.warning("[Cleanup] Request failed (\(error.localizedDescription)) — using raw text")
            return rawText
        }
    }
}
