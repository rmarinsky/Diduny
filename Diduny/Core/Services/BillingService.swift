import Foundation

nonisolated enum BillingProduct: String, Codable, Hashable {
    case pro, support, cloud
}

nonisolated struct BillingCommunity: Decodable {
    let eligible: Bool
    let url: String?
    var inviteURL: URL? {
        guard eligible, let url, let value = URL(string: url), value.scheme == "https",
              ["discord.gg", "discord.com", "t.me"].contains(value.host ?? ""),
              value.user == nil, value.password == nil else { return nil }
        return value
    }
}

nonisolated enum BillingPaymentMode: String, Codable, Hashable {
    case recurring
    case oneTime = "one_time"
}

nonisolated enum BillingInterval: String, Codable, Hashable, CaseIterable, Identifiable {
    case monthly, yearly
    var id: String {
        rawValue
    }
}

nonisolated struct BillingPlan: Decodable, Identifiable {
    let billingInterval: BillingInterval
    let amount: Decimal
    let currency: String
    let productName: String
    var paymentMode: BillingPaymentMode? = nil
    var product: BillingProduct? = nil
    var id: BillingInterval {
        billingInterval
    }

    var formattedPrice: String {
        amount.formatted(.currency(code: currency))
    }
}

nonisolated struct BillingState: Decodable {
    let plan: String
    let status: String
    let billingInterval: BillingInterval?
    let activeUntil: String?
    let renewsAt: String?
    let cancelAtPeriodEnd: Bool
    let plans: [BillingPlan]
    let pendingOrderReference: String?
    let pendingBillingInterval: BillingInterval?
    let checkoutAvailable: Bool?
    let pendingPlan: BillingPlan?
    var paymentMode: BillingPaymentMode? = nil
    var oneTimeAnnualPlan: BillingPlan? = nil
    var supportPlan: BillingPlan? = nil
    var cloudPlan: BillingPlan? = nil
    var community: BillingCommunity? = nil

    var hasTwoMonthsFree: Bool {
        guard let monthly = plans.first(where: { $0.billingInterval == .monthly }),
              let annual = plans.first(where: { $0.billingInterval == .yearly }),
              monthly.amount > 0, monthly.currency == annual.currency else { return false }
        return annual.amount == monthly.amount * 10
    }
}

@Observable
@MainActor
final class BillingService {
    nonisolated static var publicPolicyURL: URL {
        let path = Bundle.main.preferredLocalizations.first == "uk" ? "legal" : "en/legal"
        return URL(string: "https://rmarinsky.com.ua/\(path)/#diduny-offer")!
    }

    typealias Transport = @MainActor (URLRequest) async throws -> (Data, HTTPURLResponse)
    private let transport: Transport
    private let baseURL: @MainActor () -> String
    private(set) var state: BillingState?
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private var generation = 0
    private var checkoutBlocked = false
    var checkoutAvailable: Bool {
        state?.checkoutAvailable != false && !checkoutBlocked
    }

    init(baseURL: @escaping @MainActor () -> String = { SettingsStorage.shared.proxyBaseURL },
         transport: @escaping Transport = { try await AuthService.shared.performWithAuth($0) })
    {
        self.baseURL = baseURL
        self.transport = transport
    }

    func reset() {
        generation += 1
        checkoutBlocked = false
        isLoading = false
        state = nil
        errorMessage = nil
    }

    func refresh(sync: Bool = false) async {
        guard !isLoading else { return }
        isLoading = true
        let current = generation
        defer { if current == generation { isLoading = false } }
        do {
            let data = try await request(sync ? "sync" : "me", method: sync ? "POST" : "GET")
            let fetched = try JSONDecoder().decode(BillingState.self, from: data)
            guard current == generation else { return }
            state = fetched
            checkoutBlocked = false
            errorMessage = nil
        } catch { if current == generation { record(error) } }
    }

    func checkout(
        _ interval: BillingInterval,
        paymentMode: BillingPaymentMode = .recurring,
        product: BillingProduct = .pro
    ) async -> URL? {
        guard !isLoading else { return nil }
        isLoading = true
        let current = generation
        defer { if current == generation { isLoading = false } }
        do {
            let data = try await request(
                "checkout",
                method: "POST",
                interval: interval,
                paymentMode: paymentMode,
                product: product
            )
            let checkout = try JSONDecoder().decode(BillingCheckout.self, from: data)
            let url = try validatedPaymentURL(checkout.paymentUrl)
            guard current == generation else { return nil }
            errorMessage = nil
            return url
        } catch { if current == generation { record(error) }; return nil }
    }

    func abandonCheckout() async -> Bool {
        guard !isLoading else { return false }
        isLoading = true
        let current = generation
        defer { if current == generation { isLoading = false } }
        do {
            let data = try await request("abandon", method: "POST")
            let fetched = try JSONDecoder().decode(BillingState.self, from: data)
            guard current == generation else { return false }
            state = fetched; errorMessage = nil
            return fetched.pendingOrderReference == nil
        } catch { if current == generation { record(error) }; return false }
    }

    @discardableResult
    func setRenewal(enabled: Bool) async -> URL? {
        guard !isLoading else { return nil }
        isLoading = true
        let current = generation
        defer { if current == generation { isLoading = false } }
        do {
            let data = try await request(enabled ? "resume" : "cancel", method: "POST")
            if enabled, let checkout = try? JSONDecoder().decode(BillingCheckout.self, from: data) {
                let url = try validatedPaymentURL(checkout.paymentUrl)
                guard current == generation else { return nil }
                errorMessage = nil
                return url
            }
            let fetched = try JSONDecoder().decode(BillingState.self, from: data)
            guard current == generation else { return nil }
            state = fetched
            checkoutBlocked = false
            errorMessage = nil
        } catch { if current == generation { record(error) } }
        return nil
    }

    private func record(_ error: Error) {
        if case BillingError.unavailable = error { checkoutBlocked = true }
        errorMessage = error.localizedDescription
    }

    private func request(
        _ path: String,
        method: String,
        interval: BillingInterval? = nil,
        paymentMode: BillingPaymentMode = .recurring,
        product: BillingProduct = .pro
    ) async throws -> Data {
        let base = baseURL().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(base)/api/v1/billing/\(path)") else { throw BillingError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 20
        if method == "POST" {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            var body = interval.map { ["billingInterval": $0.rawValue] } ?? [:]
            if ["checkout", "resume"].contains(path) {
                body["language"] = Bundle.main.preferredLocalizations.first == "uk" ? "UA" : "EN"
            }
            if product != .pro { body["product"] = product.rawValue }
            if paymentMode == .oneTime { body["paymentMode"] = paymentMode.rawValue }
            request.httpBody = try JSONEncoder().encode(body)
        }
        let (data, response) = try await transport(request)
        guard (200 ... 299).contains(response.statusCode) else {
            struct Failure: Decodable { let error: String }
            let message = (try? JSONDecoder().decode(Failure.self, from: data))?.error
            if response.statusCode == 503, message == "Billing is not enabled" {
                throw BillingError.unavailable
            }
            throw BillingError.server(message ?? "Subscription is unavailable. Please try again.")
        }
        return data
    }

    private func validatedPaymentURL(_ value: String) throws -> URL {
        guard let url = URL(string: value), let base = URL(string: baseURL()),
              url.host == base.host, url.port == base.port, url.user == nil, url.password == nil,
              url.scheme == base.scheme,
              url.scheme == "https" || (url.scheme == "http" && ["localhost", "127.0.0.1"].contains(url.host ?? "")),
              url.path.hasPrefix("/billing/checkout/") else { throw BillingError.invalidURL }
        return url
    }
}

private enum BillingError: LocalizedError {
    case invalidURL, unavailable, server(String)
    var errorDescription: String? {
        switch self {
        case .unavailable: String(
                localized: "Payments are temporarily unavailable. Your free access is unchanged. Please try again later."
            )
        case .invalidURL: String(localized: "The payment link could not be verified. Please refresh and try again.")
        case let .server(message):
            Bundle.main.localizedString(
                forKey: message,
                value: String(
                    localized: "Could not update your subscription. Check payment status or contact support."
                ),
                table: nil
            )
        }
    }
}

private struct BillingCheckout: Decodable {
    let paymentUrl: String
}

/// An external link selects an offer only. Authentication, server pricing and payment confirmation remain required.
nonisolated struct BillingSelection: Hashable {
    let product: BillingProduct
    let interval: BillingInterval
    let paymentMode: BillingPaymentMode
    init?(url: URL) {
        guard url.scheme == "diduny", url.host == "billing", url.path.isEmpty,
              url.user == nil, url.password == nil, url.port == nil,
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let items = parts.queryItems ?? []
        guard Set(items.map(\.name)).count == items.count else { return nil }
        let value = { (name: String) in items.first { $0.name == name }?.value }
        guard let product = BillingProduct(rawValue: value("product") ?? "pro"),
              let interval = BillingInterval(rawValue: value("interval") ?? "monthly"),
              let mode = BillingPaymentMode(rawValue: value("mode") ?? "recurring"),
              product == .pro || (interval == .monthly && mode == .recurring),
              mode != .oneTime || interval == .yearly else { return nil }
        self.product = product; self.interval = interval; paymentMode = mode
    }
}
