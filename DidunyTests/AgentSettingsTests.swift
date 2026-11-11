import Foundation
import Testing
@testable import Diduny

struct AgentSettingsTests {
    @Test func acceptsValidValuesAndNormalizesThem() throws {
        #expect(try AgentSettings.validate("whisperLanguage", "UA").get() as? String == "uk")
        #expect(try AgentSettings.validate("speechLanguages", ["en", "uk", "EN"]).get() as? [String] == ["en", "uk"])
        #expect(try AgentSettings.validate("fillerWords", [" um ", "", "uh"]).get() as? [String] == ["um", "uh"])
        #expect(try AgentSettings.validate("meetingSilenceAutoStopSeconds", NSNumber(value: 90)).get() as? Double == 90)
        #expect(try AgentSettings.validate("playSoundOnCompletion", true).get() as? Bool == true)
    }

    @Test func rejectsWrongTypesRangesAndKeys() {
        #expect(throws: AgentSettings.ValidationError.self) { try AgentSettings.validate("proxyBaseURL", "https://x").get() }
        #expect(throws: AgentSettings.ValidationError.self) { try AgentSettings.validate("dictationSilenceAutoStopSeconds", NSNumber(value: 60)).get() }
        #expect(throws: AgentSettings.ValidationError.self) { try AgentSettings.validate("messageFormattingMode", "loud").get() }
        #expect(throws: AgentSettings.ValidationError.self) { try AgentSettings.validate("speechLanguages", ["klingon"]).get() }
        // JSON 1 is a number, not true; JSON true is not a number.
        #expect(throws: AgentSettings.ValidationError.self) { try AgentSettings.validate("playSoundOnCompletion", NSNumber(value: 1)).get() }
        #expect(throws: AgentSettings.ValidationError.self) { try AgentSettings.validate("meetingSilenceAutoStopSeconds", true).get() }
    }

    @Test func keepsDangerousSettingsOut() {
        let names = AgentSettings.keys.map(\.name)
        for forbidden in ["proxyBaseURL", "remoteConfigURL", "meetingHistoryRetentionPolicy", "pushToTalkKey", "preferredDeviceUID"] {
            #expect(!names.contains(forbidden))
        }
    }

    @Test func parsesCommandLineValues() {
        #expect(AgentSettings.parseArgument("on", for: "playSoundOnCompletion") as? Bool == true)
        #expect(AgentSettings.parseArgument("uk, en", for: "speechLanguages") as? [String] == ["uk", "en"])
        #expect(AgentSettings.parseArgument(#"["a","b, c"]"#, for: "fillerWords") as? [String] == ["a", "b, c"])
        #expect((AgentSettings.parseArgument("30", for: "meetingSilenceAutoStopSeconds") as? NSNumber)?.doubleValue == 30)
    }

    @Test func fileRoundTripsAndKeepsBuildsApart() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("settings.json")
        try AgentSettings.fileData(settings: ["whisperPrompt": "Diduny, Soniox"], problems: ["x: bad"]).write(to: url)
        #expect(AgentSettings.readSettings(at: url)?["whisperPrompt"] as? String == "Diduny, Soniox")
        #expect(AgentSettings.fileURL(bundleIdentifier: "ua.com.rmarinsky.diduny").lastPathComponent == "settings.json")
        #expect(AgentSettings.fileURL(bundleIdentifier: "ua.com.rmarinsky.diduny.dev").lastPathComponent == "settings.dev.json")
    }

    @Test func skillPointsAtTheGuideAndIsMarked() {
        let text = AgentSkillInstaller.skillText()
        #expect(text.hasPrefix("---\nname: "))
        #expect(text.contains(AgentSkillInstaller.marker))
        #expect(text.contains(" guide"))
    }
}
