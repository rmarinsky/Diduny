@testable import Diduny
import Foundation
import Testing

/// ADR-0012 D3 and plan default 16 rest (T4-RES-01, T4-RES-02, T1-MT-11, T1-MT-12).
@MainActor
@Suite("Effective engine resolver")
struct EffectiveEngineResolverTests {
    let modes = ModeDefaults(defaults: UserDefaults(suiteName: "test.\(UUID().uuidString)")!)
    let turbo = WhisperModelManager.WhisperModel.recommendedName
    let notDownloaded = EngineReadiness.notDownloaded(bytes: 480_000_000)

    func resolve(_ job: STTJob, segment: MeetingSegment? = nil, override: JobProviderSelection? = nil,
                 _ readiness: FakeEngineReadinessSource, downloaded: Set<String> = [], selected: String? = nil)
        -> EffectiveEngineResolver.Result {
        EffectiveEngineResolver.resolve(job: job, segment: segment, override: override, defaults: modes,
                                        readiness: readiness, whisper: .init(downloaded: downloaded, selected: selected))
    }

    @Test("An explicitly picked Parakeet that is not downloaded refuses; it never runs another engine")
    func pickedParakeetRefuses() {
        let notDownloaded = EngineReadiness.notDownloaded(bytes: 1)
        var fake = FakeEngineReadinessSource()
        fake.states[.parakeet] = notDownloaded
        let turbo = WhisperModelManager.WhisperModel.recommendedName

        #expect(resolve(.dictation, override: JobProviderSelection(providerID: "parakeet-v3"), fake, downloaded: [turbo])
            == .none(notDownloaded))
    }

    @Test("The override wins")
    func overrideWins() {
        let result = resolve(.dictation, override: JobProviderSelection(providerID: "apple-speech"), FakeEngineReadinessSource())
        #expect(result == .engine(.appleSpeech, modelID: nil))
    }

    @Test("Defaults resolve when ready; meeting uses Starts in")
    func defaultsReady() {
        #expect(resolve(.dictation, FakeEngineReadinessSource()) == .engine(.didunyCloud, modelID: nil))
        #expect(resolve(.meeting, FakeEngineReadinessSource()) == .engine(.didunyCloud, modelID: nil))
        #expect(resolve(.meeting, segment: .thisMac, FakeEngineReadinessSource()) == .engine(.whisper, modelID: nil))
    }

    @Test("Parakeet missing uses Large v3 Turbo for Record only and Files (T4-RES-01)")
    func turboFallback() {
        let fake = FakeEngineReadinessSource([.parakeet: notDownloaded])
        let expected = EffectiveEngineResolver.Result.fallback(.whisper, modelID: turbo, because: notDownloaded)
        #expect(resolve(.meeting, segment: .recordOnly, fake, downloaded: [turbo, "ggml-tiny"], selected: "ggml-tiny") == expected)
        #expect(resolve(.file, fake, downloaded: [turbo]) == expected)
    }

    @Test("Intel: unsupported hardware falls back too (T1-MT-11)")
    func intel() {
        let fake = FakeEngineReadinessSource([.parakeet: .unsupportedHardware])
        #expect(resolve(.file, fake, downloaded: [turbo]) == .fallback(.whisper, modelID: turbo, because: .unsupportedHardware))
    }

    @Test("No Turbo: the selected downloaded Whisper model, then Apple, then none (T1-MT-12)")
    func chain() {
        var fake = FakeEngineReadinessSource([.parakeet: notDownloaded])
        #expect(resolve(.file, fake, downloaded: ["ggml-tiny"], selected: "ggml-tiny")
            == .fallback(.whisper, modelID: "ggml-tiny", because: notDownloaded))
        #expect(resolve(.file, fake, selected: "ggml-tiny") == .fallback(.appleSpeech, modelID: nil, because: notDownloaded))
        fake = FakeEngineReadinessSource([.parakeet: notDownloaded, .appleSpeech: .unavailable])
        #expect(resolve(.file, fake) == .none(notDownloaded))
    }

    @Test("Other engines that are not ready do not fall back")
    func noFallbackForOthers() {
        #expect(resolve(.dictation, FakeEngineReadinessSource([.didunyCloud: .signedOut]), downloaded: [turbo]) == .none(.signedOut))
    }
}
