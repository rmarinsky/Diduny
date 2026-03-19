import Foundation
import os

final class RemoteConfigService: @unchecked Sendable {
    static let shared = RemoteConfigService()

    private let supportedVersion = 1
    private let ttlSeconds: TimeInterval = 3600 // 1 hour
    private let requestTimeout: TimeInterval = 10

    private let cacheKey = "remoteConfigCache"
    private let cacheTimestampKey = "remoteConfigCacheTimestamp"

    private var cachedConfig: RemoteConfig?
    private let lock = NSLock()

    private init() {
        loadCachedConfig()
    }

    // MARK: - Public API

    func fetchIfNeeded() async {
        let lastFetch = UserDefaults.standard.double(forKey: cacheTimestampKey)
        let elapsed = Date().timeIntervalSince1970 - lastFetch
        guard elapsed >= ttlSeconds else {
            Log.app.info("[RemoteConfig] Cache still fresh (\(Int(elapsed))s < \(Int(self.ttlSeconds))s TTL)")
            return
        }
        await fetchConfig()
    }

    func forceRefresh() async {
        UserDefaults.standard.removeObject(forKey: cacheTimestampKey)
        await fetchConfig()
    }

    // MARK: - Typed Accessors

    var maintenanceMessage: String? {
        lock.lock()
        defer { lock.unlock() }
        return cachedConfig?.messages?.maintenanceMessage
    }

    var updateAvailableMessage: String? {
        lock.lock()
        defer { lock.unlock() }
        return cachedConfig?.messages?.updateAvailableMessage
    }

    func sttBaseURL(default fallback: String) -> String {
        lock.lock()
        defer { lock.unlock() }
        return cachedConfig?.endpoints?.sttBaseURL ?? fallback
    }

    func sttModel(default fallback: String) -> String {
        lock.lock()
        defer { lock.unlock() }
        return cachedConfig?.endpoints?.sttModel ?? fallback
    }

    // MARK: - Private

    private func loadCachedConfig() {
        guard let data = UserDefaults.standard.data(forKey: cacheKey) else { return }
        do {
            let config = try JSONDecoder().decode(RemoteConfig.self, from: data)
            if let version = config.version, version != supportedVersion {
                Log.app.info("[RemoteConfig] Cached config version \(version) != \(self.supportedVersion), ignoring")
                return
            }
            cachedConfig = config
            Log.app.info("[RemoteConfig] Loaded cached config")
        } catch {
            Log.app.error("[RemoteConfig] Failed to decode cached config: \(error.localizedDescription)")
        }
    }

    private func fetchConfig() async {
        let settings = SettingsStorage.shared

        // Derive config URL: explicit remoteConfigURL, or proxy's /api/v1/config
        let urlString: String
        if let explicit = settings.remoteConfigURL, !explicit.isEmpty {
            urlString = explicit
        } else {
            let proxyBase = settings.proxyBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            urlString = "\(proxyBase)/api/v1/config"
        }

        guard let url = URL(string: urlString) else {
            Log.app.info("[RemoteConfig] Invalid config URL: \(urlString)")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = requestTimeout

        // Add auth token
        await AuthService.shared.authenticatedRequest(&request)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
                Log.app.error("[RemoteConfig] Fetch failed with status \(statusCode)")
                return
            }

            let config = try JSONDecoder().decode(RemoteConfig.self, from: data)

            if let version = config.version, version != supportedVersion {
                Log.app.info("[RemoteConfig] Server config version \(version) != \(self.supportedVersion), ignoring")
                return
            }

            lock.lock()
            cachedConfig = config
            lock.unlock()

            UserDefaults.standard.set(data, forKey: cacheKey)
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: cacheTimestampKey)

            Log.app.info("[RemoteConfig] Config fetched and cached successfully")
        } catch {
            Log.app.error("[RemoteConfig] Fetch error: \(error.localizedDescription)")
        }
    }
}
