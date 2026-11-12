import Foundation

/// Result of "Test connection" on a provider card.
enum ProviderHealth: Equatable {
    case ok(planName: String)
    case failed(ElevenLabsError)
}

/// Provider usage as the provider reports it. ElevenLabs exposes credits, not hours.
struct ProviderUsage: Equatable {
    let planName: String
    let creditsUsed: Int
    let creditsLimit: Int
    let resetsAt: Date?
}

/// `GET /v1/user/subscription`: one call serves both the connection test and the usage panel.
struct ElevenLabsAccountService {
    let session: URLSession
    let baseURL: URL

    init(session: URLSession = .shared, baseURL: URL = ElevenLabsProvider.baseURL) {
        self.session = session
        self.baseURL = baseURL
    }

    private struct Subscription: Decodable {
        let tier: String
        let characterCount: Int
        let characterLimit: Int
        let nextCharacterCountResetUnix: Int?

        enum CodingKeys: String, CodingKey {
            case tier
            case characterCount = "character_count"
            case characterLimit = "character_limit"
            case nextCharacterCountResetUnix = "next_character_count_reset_unix"
        }
    }

    func testConnection(apiKey: String) async -> ProviderHealth {
        do {
            return .ok(planName: try await fetchUsage(apiKey: apiKey).planName)
        } catch ElevenLabsError.userReadNotGranted {
            // The subscription call needs User (read); a key restricted to Speech to Text still transcribes.
            return .ok(planName: "")
        } catch {
            return .failed(ElevenLabsError.from(transportError: error))
        }
    }

    func fetchUsage(apiKey: String) async throws -> ProviderUsage {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/user/subscription"))
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ElevenLabsError.network
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200 ..< 300).contains(status) else {
            // Only the explicit code means "valid key without User (read)"; any other 403 stays a failure.
            if ElevenLabsError.isMissingPermissionsCode(data) { throw ElevenLabsError.userReadNotGranted }
            throw ElevenLabsError.from(httpStatus: status, body: data)
        }
        guard let subscription = try? JSONDecoder().decode(Subscription.self, from: data) else {
            throw ElevenLabsError.invalidResponse
        }
        return ProviderUsage(
            planName: subscription.tier,
            creditsUsed: subscription.characterCount,
            creditsLimit: subscription.characterLimit,
            resetsAt: subscription.nextCharacterCountResetUnix.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        )
    }
}
