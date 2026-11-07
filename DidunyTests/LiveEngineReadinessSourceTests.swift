@testable import Diduny
import Testing

/// ADR-0012 D1: the live readiness adapter (replaces the interim Modes readiness).
@MainActor
@Suite("Live engine readiness")
struct LiveEngineReadinessSourceTests {
    func source(key: Bool = false, appleSilicon: Bool = true, parakeet: Bool = false, apple: Bool = true)
        -> LiveEngineReadinessSource {
        LiveEngineReadinessSource(hasKey: { _ in key }, isAppleSilicon: { appleSilicon },
                                  isParakeetDownloaded: { parakeet }, appleSpeechOnThisMac: { apple })
    }

    @Test("Key, download, hardware and Apple Speech")
    func states() {
        #expect(source().readiness(of: .didunyCloud) == .ready)
        #expect(source().readiness(of: .whisper) == .ready)
        #expect(source().readiness(of: .elevenLabs) == .needsKey)
        #expect(source(key: true).readiness(of: .elevenLabs) == .ready)
        if case .notDownloaded = source().readiness(of: .parakeet) {} else { Issue.record("Parakeet should be not downloaded") }
        #expect(source(parakeet: true).readiness(of: .parakeet) == .ready)
        #expect(source(appleSilicon: false, parakeet: true).readiness(of: .parakeet) == .unsupportedHardware)
        #expect(source().readiness(of: .appleSpeech) == .ready)
        #expect(source(apple: false).readiness(of: .appleSpeech) == .unavailable)
    }
}
