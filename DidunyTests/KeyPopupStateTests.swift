@testable import Diduny
import Foundation
import Testing

/// Key popup and "Add ElevenLabs" (03 3.2, decision 6; T3-KEY-01..09 at unit level). In-memory key store and
/// a stub account: no Keychain, no network.
@MainActor
final class KeyPopupStateTests {
    private let suiteName = "KeyPopupStateTests.\(UUID().uuidString)"
    private let defaults: UserDefaults
    private let backend = InMemoryKeyBackend()
    private let keyStore: ProviderKeyStore
    private let id = STTProviderID.elevenLabs

    init() throws {
        defaults = try #require(UserDefaults(suiteName: suiteName))
        keyStore = ProviderKeyStore(backend: backend)
    }

    deinit {
        UserDefaults().removePersistentDomain(forName: suiteName)
    }

    private var jobDefaults: ProviderDefaultsStore {
        ProviderDefaultsStore(defaults: defaults, knownProviderIDs: [STTProviderID.didunyCloud, id])
    }

    private func popup(_ mode: StubElevenLabsAccount.Mode = .works) throws -> KeyPopupState {
        try keyStore.save(ProviderUITesting.fakeKey, for: id)
        return KeyPopupState(keyStore: keyStore, account: StubElevenLabsAccount(mode: mode), defaults: jobDefaults)
    }

    @Test("Refresh fills Connection and Used this month")
    func refresh() async throws {
        let state = try popup()
        #expect(state.maskedKey == "••••••••4f2a")
        await state.refresh()
        #expect(state.connection.text == "Works")
        #expect(state.usage.text(locale: Locale(identifier: "en_US")) == "12,400 of 100,000 credits")
    }

    @Test("A failed test shows the status and today's detail line")
    func networkFailure() async throws {
        let state = try popup(.network)
        await state.test()
        #expect(state.connection.text == "Network error")
        #expect(state.connection.detail == "Can't reach ElevenLabs. Your key is unchanged.")
        #expect(keyStore.hasKey(for: id))
    }

    @Test("Remove asks first; Keep puts Remove back and the key stays")
    func removeAsksFirst() throws {
        let state = try popup()
        #expect(state.confirmRemove().isEmpty)
        #expect(keyStore.hasKey(for: id))
        state.armRemove()
        #expect(state.removeArmed)
        state.keep()
        #expect(!state.removeArmed)
        #expect(keyStore.hasKey(for: id))
    }

    @Test("Remove the key erases it and sends its modes back to Diduny Cloud")
    func removeResetsModes() throws {
        let state = try popup()
        jobDefaults.setSelection(JobProviderSelection(providerID: id, modelID: nil), for: .dictation)
        jobDefaults.setSelection(JobProviderSelection(providerID: id, modelID: nil), for: .meeting)
        var reported: [STTJob] = []
        state.onRemoved = { reported = $0 }
        state.armRemove()
        let affected = state.confirmRemove()
        #expect(Set(affected) == [.dictation, .meeting])
        #expect(reported == affected)
        #expect(!keyStore.hasKey(for: id))
        #expect(state.maskedKey == nil)
        #expect(jobDefaults.selection(for: .dictation).providerID == STTProviderID.didunyCloud)
        #expect(jobDefaults.selection(for: .meeting).providerID == STTProviderID.didunyCloud)
    }

    @Test("Closing the popup resets an armed remove and an open replace")
    func closeResets() throws {
        let state = try popup()
        state.armRemove()
        state.beginReplace()
        state.replacement = "draft"
        state.popupClosed()
        #expect(!state.removeArmed)
        #expect(!state.isReplacing)
        #expect(state.replacement.isEmpty)
    }

    @Test("Replace: Cancel keeps the old key, Save stores the new one")
    func replace() async throws {
        let state = try popup()
        state.beginReplace()
        state.replacement = "replacement-key-9z9z"
        state.cancelReplace()
        #expect(keyStore.key(for: id) == ProviderUITesting.fakeKey)
        state.beginReplace()
        state.replacement = "  replacement-key-9z9z \n"
        await state.saveReplacement()
        #expect(keyStore.key(for: id) == "replacement-key-9z9z")
        #expect(state.maskedKey == "••••••••9z9z")
        #expect(!state.isReplacing)
    }

    @Test("Replace with a rejected key restores the old key and shows Invalid key")
    func replaceInvalid() async throws {
        let state = try popup(.invalid)
        state.beginReplace()
        state.replacement = "replacement-key-9z9z"
        await state.saveReplacement()
        #expect(keyStore.key(for: id) == ProviderUITesting.fakeKey)
        #expect(state.maskedKey == "••••••••4f2a")
        #expect(state.connection.text == "Invalid key")
        #expect(state.isReplacing)
    }

    @Test("Add: Save is disabled while empty; a working key is kept")
    func addWorks() async {
        let add = AddKeyState(keyStore: keyStore, account: StubElevenLabsAccount(mode: .works))
        #expect(!add.canSave)
        add.input = "new-key-abcd1234"
        #expect(add.canSave)
        #expect(await add.save())
        #expect(add.phase == .saved)
        #expect(keyStore.hasKey(for: id))
    }

    @Test("Add: a rejected key is not saved")
    func addInvalid() async {
        let add = AddKeyState(keyStore: keyStore, account: StubElevenLabsAccount(mode: .invalid))
        add.input = "bad-key-abcd1234"
        #expect(!(await add.save()))
        #expect(add.message == "ElevenLabs rejected this key. Check it and paste it again.")
        #expect(!keyStore.hasKey(for: id))
    }

    @Test("Add: a network failure keeps the key")
    func addNetwork() async {
        let add = AddKeyState(keyStore: keyStore, account: StubElevenLabsAccount(mode: .network))
        add.input = "net-key-abcd1234"
        #expect(await add.save())
        #expect(keyStore.hasKey(for: id))
    }
}
