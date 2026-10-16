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
        if usage.hasUnlimitedAccess { return String(localized: "Unlimited") }
        guard let remaining = usage.remainingHours else { return "—" }
        return String(format: String(localized: "%.1fh remaining"), locale: Locale.current, remaining)
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
    var hasUnlimitedAccess: Bool {
        isUnlimited == true || isWhitelisted
    }

    init(
        isWhitelisted: Bool,
        usedHours: Double,
        limitHours: Double?,
        remainingHours: Double?,
        usedMs: Int,
        limitMs: Int?,
        remainingMs: Int?,
        isUnlimited: Bool? = nil
    ) {
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

/// Optional product statistics. No disk queue, content, or offline history upload.
@Observable
@MainActor
final class AnalyticsService {
    static let shared = AnalyticsService()
    private(set) var enabled = false
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private var revision: String?
    private var owner: String?
    private var generation = 0
    private var operationID: UUID?
    private let baseURL: @MainActor () -> String
    private let account: @MainActor () -> String?
    private let transport: BillingService.Transport

    init(baseURL: @escaping @MainActor () -> String = { SettingsStorage.shared.proxyBaseURL },
         account: @escaping @MainActor ()
             -> String? = { AuthService.shared.isLoggedIn ? AuthService.shared.userEmail : nil },
         transport: @escaping BillingService.Transport = { try await AuthService.shared.performWithAuth($0) })
    {
        self.baseURL = baseURL
        self.account = account
        self.transport = transport
    }

    func reset() {
        generation += 1
        operationID = nil
        enabled = false
        revision = nil
        owner = nil
        isLoading = false
        errorMessage = nil
    }

    func refresh() async {
        await update(choice: nil)
    }

    func setEnabled(_ value: Bool) async {
        await update(choice: value)
    }

    private func update(choice: Bool?) async {
        guard let currentAccount = account() else { reset(); return }
        let withdrawalKey = "analytics.withdrawal." + baseURL() + "." + currentAccount
        if choice == false, isLoading {
            enabled = false
            revision = nil
            generation += 1
            UserDefaults.standard.set(true, forKey: withdrawalKey)
            return
        }
        guard !isLoading else { return }
        if owner != currentAccount { reset() }
        owner = currentAccount
        let current = generation
        // Withdrawal is immediate locally even if the server is unreachable.
        if choice == false {
            enabled = false; revision = nil
            UserDefaults.standard.set(true, forKey: withdrawalKey)
        }
        let effectiveChoice = choice ?? (UserDefaults.standard.bool(forKey: withdrawalKey) ? false : nil)
        isLoading = true
        let operation = UUID()
        operationID = operation
        defer {
            if operationID == operation {
                isLoading = false
                operationID = nil
                if current != generation, owner == currentAccount, account() == currentAccount,
                   UserDefaults.standard.bool(forKey: withdrawalKey)
                {
                    Task { await self.setEnabled(false) }
                }
            }
        }
        do {
            var request = try request(path: "consent")
            request.httpMethod = effectiveChoice == nil ? "GET" : "PUT"
            if let effectiveChoice { request.httpBody = try JSONEncoder().encode(["enabled": effectiveChoice]) }
            let (data, response) = try await transport(request)
            guard current == generation, account() == currentAccount else { return }
            guard response.statusCode == 200 else { throw URLError(.badServerResponse) }
            struct Consent: Decodable { let enabled: Bool; let revision: String? }
            let consent = try JSONDecoder().decode(Consent.self, from: data)
            UserDefaults.standard.removeObject(forKey: withdrawalKey)
            enabled = consent.enabled
            revision = consent.revision
            errorMessage = nil
        } catch {
            guard current == generation, account() == currentAccount else { return }
            errorMessage = choice == false
                ?
                String(
                    localized: "Statistics are off on this device. Connect to the internet and turn off sharing again to update your account."
                )
                : String(localized: "Could not update statistics sharing. Try again when online.")
        }
    }

    func record(duration: TimeInterval, mode: String, scenario: String) async {
        guard enabled, owner == account(), owner != nil, let revision,
              duration.isFinite, duration > 0, duration <= 86400,
              ["local", "cloud"].contains(mode),
              ["dictation", "meeting", "file", "translation"].contains(scenario) else { return }
        let current = generation
        do {
            struct Event: Encodable {
                let id: UUID; let revision: String; let durationMs: Int; let mode: String; let scenario: String
            }
            var request = try request(path: "events")
            request.httpMethod = "POST"
            request.httpBody = try JSONEncoder().encode(Event(
                id: UUID(),
                revision: revision,
                durationMs: max(1, Int(duration * 1000)),
                mode: mode,
                scenario: scenario
            ))
            let (_, response) = try await transport(request)
            if current == generation, response.statusCode == 403 { enabled = false; self.revision = nil }
        } catch {
            // Best-effort analytics must never block work or retain offline events.
        }
    }

    private func request(path: String) throws -> URLRequest {
        guard let url = URL(string: baseURL()
            .trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/api/v1/analytics/" + path)
        else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }
}
