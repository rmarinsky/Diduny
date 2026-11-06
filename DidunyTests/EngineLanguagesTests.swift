@testable import Diduny
import Foundation
import Testing

/// T3-CAP-07, T3-CAP-08: language data per engine, names for codes outside the 60, matching by code.
struct EngineLanguagesTests {
    static let english = Locale(identifier: "en")

    static func languages(_ id: EngineID) throws -> EngineLanguageList {
        try EngineCapabilitiesTests.capabilities(id).traits.languages
    }

    struct Counts: CustomTestStringConvertible, Sendable {
        let engine: EngineID
        /// nil = set by macOS, no list.
        let groupSizes: [Int]?
        let groupTitles: [String?]
        var testDescription: String { engine.rawValue }
    }

    static let counts: [Counts] = [
        Counts(engine: .didunyCloud, groupSizes: [60], groupTitles: [nil]),
        Counts(engine: .elevenLabs, groupSizes: [36, 21, 18, 19],
               groupTitles: ["Excellent accuracy", "High accuracy", "Good accuracy", "Moderate accuracy"]),
        Counts(engine: .whisper, groupSizes: [100], groupTitles: [nil]),
        Counts(engine: .parakeet, groupSizes: [25], groupTitles: [nil]),
        Counts(engine: .appleSpeech, groupSizes: nil, groupTitles: [])
    ]

    @Test("Language counts and groups", arguments: counts)
    func languageCounts(_ row: Counts) throws {
        let list = try Self.languages(row.engine)
        switch list {
        case .system:
            #expect(row.groupSizes == nil)
            #expect(list.count == nil)
            #expect(list.languages.isEmpty)
        case let .groups(groups):
            #expect(groups.map(\.languages.count) == row.groupSizes)
            #expect(groups.map(\.title) == row.groupTitles)
            #expect(list.count == row.groupSizes?.reduce(0, +))
        }
    }

    @Test("No engine lists a language twice", arguments: EngineID.allCases)
    func noDuplicates(_ engine: EngineID) throws {
        let codes = try Self.languages(engine).languages.map(\.code)
        #expect(Set(codes).count == codes.count)
    }

    @Test("Diduny Cloud lists the 60 cloud languages in their order")
    func cloudListIsTheSixty() throws {
        #expect(try Self.languages(.didunyCloud).languages.map(\.code) == SupportedLanguage.cloudLanguages.map(\.code))
    }

    @Test("Maltese is listed where the engine supports it", arguments: EngineID.allCases)
    func maltese(_ engine: EngineID) throws {
        let listed = try Self.languages(engine).languages.contains { $0.code == "mt" }
        #expect(listed == [.elevenLabs, .whisper, .parakeet].contains(engine))
    }

    @Test("Codes outside the 60 have names that do not depend on SupportedLanguage")
    func namesOutsideTheSixty() throws {
        let maltese = try #require(Self.languages(.parakeet).languages.first { $0.code == "mt" })
        #expect(SupportedLanguage.normalizedCode("mt") == nil)
        #expect(EngineLanguages.name(of: maltese, locale: Self.english) == "Maltese")
        let cloud = Set(SupportedLanguage.cloudLanguages.map(\.code))
        for engine in EngineID.allCases {
            for language in try Self.languages(engine).languages where !cloud.contains(language.code) {
                #expect(EngineLanguages.fallbackNames[language.code] != nil, "\(engine.rawValue): \(language.code)")
            }
        }
    }

    @Test("Every listed language has a name", arguments: EngineID.allCases)
    func everyLanguageHasAName(_ engine: EngineID) throws {
        for language in try Self.languages(engine).languages {
            let name = EngineLanguages.name(of: language, locale: Self.english)
            #expect(!name.isEmpty && name != language.code && name != language.vendorCode, "\(language.vendorCode)")
        }
    }

    static let codeMap: [(String, String)] = [
        ("ukr", "uk"), ("eng", "en"), ("deu", "de"), ("cmn", "zh"), ("fil", "tl"),
        ("yue", "yue"), ("mlt", "mt"), ("nor", "no"), ("ast", "ast"), ("nso", "nso")
    ]

    @Test("ElevenLabs ISO 639-3 codes map to the app's codes", arguments: codeMap)
    func elevenLabsCodeMap(_ iso3: String, _ code: String) {
        #expect(EngineLanguages.elevenLabsCodes[iso3] == code)
    }

    @Test("ElevenLabs list keeps the code ElevenLabs prints")
    func elevenLabsVendorCodes() throws {
        let list = try Self.languages(.elevenLabs).languages
        #expect(EngineLanguages.elevenLabsCodes.count == 94)
        #expect(Set(list.map(\.vendorCode)) == Set(EngineLanguages.elevenLabsCodes.keys))
        for language in list {
            #expect(EngineLanguages.elevenLabsCodes[language.vendorCode] == language.code)
        }
    }

    @Test("Your languages are matched by code")
    func yourLanguagesMatchByCode() throws {
        let marked = try Self.languages(.elevenLabs).marked(by: ["uk", "zh"])
        #expect(Set(marked.map(\.vendorCode)) == ["ukr", "cmn"])
        #expect(try Self.languages(.whisper).marked(by: ["UK", "pt-BR"]).map(\.code) == ["pt", "uk"])
        #expect(try Self.languages(.appleSpeech).marked(by: ["uk"]).isEmpty)
    }

    @Test("Set in macOS gates nothing")
    func systemSupportsEveryLanguage() {
        #expect(LanguageSupport.system.supports("mt"))
        #expect(LanguageSupport.system.supports("auto"))
    }
}
