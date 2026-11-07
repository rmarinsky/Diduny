import Foundation
import Observation

/// The two ElevenLabs account calls the key UI makes; tests and UI tests use a fake.
protocol ElevenLabsAccountChecking: Sendable {
    func testConnection(apiKey: String) async -> ProviderHealth
    func fetchUsage(apiKey: String) async throws -> ProviderUsage
}

extension ElevenLabsAccountService: ElevenLabsAccountChecking {
    /// 10 s timeout, as the old Providers card used.
    static var settings: any ElevenLabsAccountChecking {
        #if DEBUG || TEST_BUILD
            if let stub = ProviderUITesting.accountStub { return stub }
        #endif
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        return ElevenLabsAccountService(session: URLSession(configuration: config))
    }
}

/// Connection row text (03 3.2 B, proposed states from today's pill).
enum KeyConnection: Equatable {
    case notTested
    case testing
    case works(plan: String)
    case failed(ElevenLabsError)

    var text: String {
        switch self {
        case .notTested: String(localized: "Not tested yet.")
        case .testing: String(localized: "Testing...")
        case .works: String(localized: "Works")
        case let .failed(error):
            switch error {
            case .invalidKey: String(localized: "Invalid key")
            case .missingPermission: String(localized: "Missing permission")
            case .termsNotAccepted: String(localized: "Terms not accepted")
            case .network: String(localized: "Network error")
            default: String(localized: "Test failed")
            }
        }
    }

    /// Today's detail line, under the row for a failure.
    var detail: String? {
        guard case let .failed(error) = self else { return nil }
        return switch error {
        case .invalidKey: String(localized: "ElevenLabs rejected this key. Check it and paste it again.")
        case .missingPermission: String(localized: "This key lacks the speech_to_text permission. Enable it for the key in the ElevenLabs dashboard.")
        case .termsNotAccepted: String(localized: "Accept the Scribe terms in your ElevenLabs dashboard, then test again.")
        case .network: String(localized: "Can't reach ElevenLabs. Your key is unchanged.")
        default: error.errorDescription
        }
    }
}

enum KeyUsage: Equatable {
    case loading
    case loaded(ProviderUsage)
    case unavailable

    /// "12 400 of 100 000 credits".
    func text(locale: Locale = EngineLanguages.appLocale) -> String {
        switch self {
        case .loading: return "…"
        case .unavailable: return String(localized: "Usage unavailable right now.")
        case let .loaded(usage):
            let used = usage.creditsUsed.formatted(.number.locale(locale))
            guard usage.creditsLimit > 0 else { return String(localized: "\(used) credits") }
            let limit = usage.creditsLimit.formatted(.number.locale(locale))
            return String(localized: "\(used) of \(limit) credits")
        }
    }
}

/// The key popup (03 3.2 B): Key with Replace, Connection with Test, Used this month, and Remove that asks
/// first ("Remove the key" / "Keep", decision 6).
@MainActor
@Observable
final class KeyPopupState {
    private(set) var maskedKey: String?
    private(set) var connection: KeyConnection = .notTested
    private(set) var usage: KeyUsage = .loading
    private(set) var isReplacing = false
    var replacement = ""
    private(set) var replaceFailed = false
    /// After the first click on "Remove": the button reads "Remove the key" and "Keep" appears.
    private(set) var removeArmed = false

    @ObservationIgnored private let keyStore: ProviderKeyStore
    @ObservationIgnored private let providerID: String
    @ObservationIgnored private let account: any ElevenLabsAccountChecking
    @ObservationIgnored private let defaults: ProviderDefaultsStore
    /// Called after the key is removed, with the jobs that went back to Diduny Cloud.
    @ObservationIgnored var onRemoved: ([STTJob]) -> Void = { _ in }

    init(
        keyStore: ProviderKeyStore,
        providerID: String = STTProviderID.elevenLabs,
        account: any ElevenLabsAccountChecking,
        defaults: ProviderDefaultsStore
    ) {
        self.keyStore = keyStore
        self.providerID = providerID
        self.account = account
        self.defaults = defaults
        maskedKey = keyStore.maskedKey(for: providerID)
    }

    /// One subscription call fills both Connection and Used this month.
    func refresh() async {
        guard let key = keyStore.key(for: providerID) else { return }
        connection = .testing
        usage = .loading
        do {
            let value = try await account.fetchUsage(apiKey: key)
            connection = .works(plan: value.planName)
            usage = .loaded(value)
        } catch {
            connection = .failed(error as? ElevenLabsError ?? .network)
            usage = .unavailable
        }
    }

    func test() async {
        guard let key = keyStore.key(for: providerID) else { return }
        connection = .testing
        switch await account.testConnection(apiKey: key) {
        case let .ok(plan): connection = .works(plan: plan)
        case let .failed(error): connection = .failed(error)
        }
    }

    func beginReplace() {
        replacement = ""
        replaceFailed = false
        isReplacing = true
    }

    func cancelReplace() {
        replacement = ""
        isReplacing = false
    }

    var canSaveReplacement: Bool {
        !replacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Checks the new key as Add does; ElevenLabs rejecting it restores the old key and keeps the field open.
    func saveReplacement() async {
        guard canSaveReplacement else { return }
        let previous = keyStore.key(for: providerID)
        do {
            try keyStore.save(replacement, for: providerID)
        } catch {
            replaceFailed = true
            return
        }
        connection = .testing
        if case .failed(.invalidKey) = await account.testConnection(apiKey: keyStore.key(for: providerID) ?? "") {
            if let previous { try? keyStore.save(previous, for: providerID) }
            connection = .failed(.invalidKey)
            return
        }
        cancelReplace()
        maskedKey = keyStore.maskedKey(for: providerID)
        await refresh()
    }

    func armRemove() { removeArmed = true }
    func keep() { removeArmed = false }

    /// Second click: erases the key and sends the modes that used it back to Diduny Cloud.
    @discardableResult
    func confirmRemove() -> [STTJob] {
        guard removeArmed else { return [] }
        removeArmed = false
        let affected = keyStore.remove(for: providerID, defaults: defaults)
        maskedKey = nil
        onRemoved(affected)
        return affected
    }

    /// The popup closed: an armed remove and an open replace do not survive (03 3.2 B item 5, proposed).
    func popupClosed() {
        removeArmed = false
        cancelReplace()
    }
}

/// "Add ElevenLabs" (03 3.2 A): field and Save, shown only without a key. Save stores the key, checks it,
/// and drops it again when ElevenLabs rejects it.
@MainActor
@Observable
final class AddKeyState {
    enum Phase: Equatable {
        case idle
        case checking
        case invalid
        case keychainFailed
        case saved
    }

    var input = ""
    private(set) var phase: Phase = .idle

    @ObservationIgnored private let keyStore: ProviderKeyStore
    @ObservationIgnored private let providerID: String
    @ObservationIgnored private let account: any ElevenLabsAccountChecking

    init(keyStore: ProviderKeyStore, providerID: String = STTProviderID.elevenLabs, account: any ElevenLabsAccountChecking) {
        self.keyStore = keyStore
        self.providerID = providerID
        self.account = account
    }

    var canSave: Bool {
        phase != .checking && !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var message: String? {
        switch phase {
        case .invalid: String(localized: "ElevenLabs rejected this key. Check it and paste it again.")
        case .keychainFailed: String(localized: "Couldn't save the key to Keychain.")
        case .idle, .checking, .saved: nil
        }
    }

    /// true when the key is kept. A network failure keeps the key (today's "Your key is unchanged.").
    @discardableResult
    func save() async -> Bool {
        guard canSave else { return false }
        do {
            try keyStore.save(input, for: providerID)
        } catch {
            phase = .keychainFailed
            return false
        }
        phase = .checking
        let key = keyStore.key(for: providerID) ?? ""
        if case .failed(.invalidKey) = await account.testConnection(apiKey: key) {
            keyStore.delete(for: providerID)
            phase = .invalid
            return false
        }
        input = ""
        phase = .saved
        let id = providerID
        Task { await RemoteDeletionQueue.shared.resetAuthNotice(for: id) }
        return true
    }
}
