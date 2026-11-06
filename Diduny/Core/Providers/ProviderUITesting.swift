#if DEBUG || TEST_BUILD
    import Foundation

    /// UI-test seams for the ElevenLabs key (test-plan 2.2, 2.5): `--ui-testing-elevenlabs-key=present|absent`
    /// puts `ProviderKeyStore.shared` on an in-memory store (never the Keychain), and
    /// `DIDUNY_UI_TEST_ELEVENLABS_TEST` (`works`, `invalid`, `network`) answers the account calls. Fake key only.
    enum ProviderUITesting {
        static let keyArgument = "--ui-testing-elevenlabs-key="
        static let accountEnvironment = "DIDUNY_UI_TEST_ELEVENLABS_TEST"
        /// Not a real key; ends in "4f2a" as the prototype's masked key.
        static let fakeKey = "ui-test-fake-elevenlabs-4f2a"

        static let keyBackend: InMemoryKeyBackend? = {
            guard let value = argumentValue(keyArgument) else { return nil }
            let backend = InMemoryKeyBackend()
            if value == "present" {
                try? backend.save(key: ProviderKeyStore.account(for: STTProviderID.elevenLabs), value: fakeKey)
            }
            return backend
        }()

        static let accountStub: StubElevenLabsAccount? = {
            guard argumentValue(keyArgument) != nil else { return nil }
            let mode = ProcessInfo.processInfo.environment[accountEnvironment] ?? "works"
            return StubElevenLabsAccount(mode: StubElevenLabsAccount.Mode(rawValue: mode) ?? .works)
        }()

        private static func argumentValue(_ prefix: String) -> String? {
            ProcessInfo.processInfo.arguments.first { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
        }
    }

    /// Keychain stand-in held in memory. Also the unit tests' key store backend.
    final class InMemoryKeyBackend: AuthTokenStore, @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String: String] = [:]

        func save(key: String, value: String) throws { lock.withLock { items[key] = value } }
        func read(key: String) -> String? { lock.withLock { items[key] } }
        func delete(key: String) { lock.withLock { items[key] = nil } }
    }

    /// Account answers without network: usage "12 400 of 100 000 credits".
    struct StubElevenLabsAccount: ElevenLabsAccountChecking {
        enum Mode: String, Sendable { case works, invalid, network }
        let mode: Mode

        static let usage = ProviderUsage(planName: "creator", creditsUsed: 12400, creditsLimit: 100_000, resetsAt: nil)

        func testConnection(apiKey _: String) async -> ProviderHealth {
            switch mode {
            case .works: .ok(planName: Self.usage.planName)
            case .invalid: .failed(.invalidKey)
            case .network: .failed(.network)
            }
        }

        func fetchUsage(apiKey _: String) async throws -> ProviderUsage {
            switch mode {
            case .works: Self.usage
            case .invalid: throw ElevenLabsError.invalidKey
            case .network: throw ElevenLabsError.network
            }
        }
    }
#endif
