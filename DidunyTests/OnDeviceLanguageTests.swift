@testable import Diduny
import Foundation
import Testing

struct OnDeviceLanguageTests {
    /// Stands in for an on-device engine: records the language it is given.
    final class FakeOnDevice: @unchecked Sendable {
        var received: [String] = []
        func transcribe(_ url: URL, language: String) -> String { received.append(language); return "" }
    }

    @Test func severalLanguagesLetTheEngineDetect() {
        #expect(OnDeviceLanguage.resolve(hints: ["en", "uk"]) == nil)
        let fake = FakeOnDevice()
        _ = fake.transcribe(URL(fileURLWithPath: "/dev/null"), language: OnDeviceLanguage.engineArgument(hints: ["en", "uk"]))
        #expect(fake.received == [BenchmarkRun.autoLanguage])
    }

    @Test func oneLanguageIsForced() {
        #expect(OnDeviceLanguage.resolve(hints: ["uk"]) == "uk")
        let fake = FakeOnDevice()
        _ = fake.transcribe(URL(fileURLWithPath: "/dev/null"), language: OnDeviceLanguage.engineArgument(hints: ["uk"]))
        #expect(fake.received == ["uk"])
    }

    @Test func explicitChoiceWins() {
        #expect(OnDeviceLanguage.resolve(hints: ["en", "uk"], explicit: "uk") == "uk")
        #expect(OnDeviceLanguage.resolve(hints: ["en"], explicit: "uk") == "uk")
    }

    @Test func noHintsDetects() {
        #expect(OnDeviceLanguage.resolve(hints: []) == nil)
    }
}
