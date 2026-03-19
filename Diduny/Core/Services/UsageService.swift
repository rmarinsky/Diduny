import Foundation
import os

@Observable
@MainActor
final class UsageService {
    static let shared = UsageService()

    private(set) var cachedUsage: UsageResponse?
    private(set) var isLoading = false
    private(set) var lastFetched: Date?

    private init() {}

    var formattedRemaining: String {
        guard let usage = cachedUsage else { return "—" }
        if usage.isWhitelisted { return "Unlimited" }
        guard let remaining = usage.remainingHours else { return "—" }
        return String(format: "%.1fh remaining", remaining)
    }

    var usagePercent: Double {
        guard let usage = cachedUsage, !usage.isWhitelisted,
              let limitMs = usage.limitMs, limitMs > 0
        else { return 0 }
        return Double(usage.usedMs) / Double(limitMs)
    }

    func refresh() async {
        let proxyBase = SettingsStorage.shared.proxyBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(proxyBase)/api/v1/usage/me") else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        isLoading = true
        defer { isLoading = false }

        do {
            let (data, httpResponse) = try await AuthService.shared.performWithAuth(request)
            guard (200 ... 299).contains(httpResponse.statusCode) else {
                Log.app.warning("[Usage] Failed to fetch usage: HTTP \(httpResponse.statusCode)")
                return
            }
            cachedUsage = try JSONDecoder().decode(UsageResponse.self, from: data)
            lastFetched = Date()
            Log.app.info("[Usage] Refreshed: \(self.formattedRemaining)")
        } catch {
            Log.app.warning("[Usage] Failed to fetch usage: \(error.localizedDescription)")
        }
    }
}

struct UsageResponse: Decodable {
    let isWhitelisted: Bool
    let usedHours: Double
    let limitHours: Double?
    let remainingHours: Double?
    let usedMs: Int
    let limitMs: Int?
    let remainingMs: Int?
}

struct UsageLimitErrorResponse: Decodable {
    let error: String
    let usedHours: Double
    let limitHours: Double
}
