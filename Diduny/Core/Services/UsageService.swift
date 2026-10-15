import Foundation
import os

@Observable
@MainActor
final class UsageService {
    static let shared = UsageService()
    nonisolated static let freeCloudLimitHours: Double = 2

    private(set) var cachedUsage: UsageResponse?
    private(set) var isLoading = false
    private(set) var lastFetched: Date?

    private init() {}

    nonisolated static func canUseCloudTranscription(
        hasStoredSession: Bool,
        usage: UsageResponse?
    ) -> Bool {
        guard hasStoredSession, let usage else { return false }
        return usage.hasUnlimitedAccess || (usage.remainingMs ?? 0) > 0
    }

    nonisolated static func canOfferCloudTranscription(
        hasStoredSession: Bool,
        usage: UsageResponse?
    ) -> Bool {
        hasStoredSession && (usage == nil || canUseCloudTranscription(hasStoredSession: true, usage: usage))
    }

    var formattedRemaining: String {
        guard let usage = cachedUsage else { return "—" }
        if usage.hasUnlimitedAccess { return "Unlimited" }
        guard let remaining = usage.remainingHours else { return "—" }
        return String(format: "%.1fh remaining", remaining)
    }

    var usagePercent: Double {
        guard let usage = cachedUsage, !usage.hasUnlimitedAccess,
              let limitMs = usage.limitMs, limitMs > 0
        else { return 0 }
        return Double(usage.usedMs) / Double(limitMs)
    }

    @discardableResult
    func refresh() async -> UsageResponse? {
        let proxyBase = SettingsStorage.shared.proxyBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(proxyBase)/api/v1/usage/me") else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        isLoading = true
        defer { isLoading = false }

        do {
            let (data, httpResponse) = try await AuthService.shared.performWithAuth(request)
            guard (200 ... 299).contains(httpResponse.statusCode) else {
                Log.app.warning("[Usage] Failed to fetch usage: HTTP \(httpResponse.statusCode)")
                return nil
            }
            let usage = try JSONDecoder().decode(UsageResponse.self, from: data)
            cachedUsage = usage
            lastFetched = Date()
            Log.app.info("[Usage] Refreshed: \(self.formattedRemaining)")
            return usage
        } catch {
            Log.app.warning("[Usage] Failed to fetch usage: \(error.localizedDescription)")
            return nil
        }
    }
}

struct UsageResponse: Decodable {
    let isWhitelisted: Bool
    let isUnlimited: Bool?
    var hasUnlimitedAccess: Bool { isUnlimited == true || isWhitelisted }

    init(isWhitelisted: Bool, usedHours: Double, limitHours: Double?, remainingHours: Double?, usedMs: Int, limitMs: Int?, remainingMs: Int?, isUnlimited: Bool? = nil) {
        self.isWhitelisted = isWhitelisted
        self.isUnlimited = isUnlimited
        self.usedHours = usedHours
        self.limitHours = limitHours
        self.remainingHours = remainingHours
        self.usedMs = usedMs
        self.limitMs = limitMs
        self.remainingMs = remainingMs
    }
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
