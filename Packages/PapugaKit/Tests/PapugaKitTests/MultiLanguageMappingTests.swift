import XCTest
import Carbon.HIToolbox
@testable import PapugaKit

/// Layout-specific character-mapping tests for popular language pairs.
/// Each test is skipped if the relevant input source is not installed.
final class MultiLanguageMappingTests: XCTestCase {
    private var mapper = CharacterMapper()

    override func setUp() {
        super.setUp()
        mapper = CharacterMapper()
    }

    private func source(forID id: String) throws -> TISInputSource {
        let conditions = [kTISPropertyInputSourceID!: id as CFString] as CFDictionary
        guard let list = TISCreateInputSourceList(conditions, true)?.takeRetainedValue() as? [TISInputSource],
              let s = list.first else {
            throw XCTSkip("Input source \(id) is not present on this Mac.")
        }
        return s
    }

    private func assertConvert(
        _ input: String,
        from: String,
        to: String,
        expected: String,
        file: StaticString = #file,
        line: UInt = #line
    ) throws {
        let fromSrc = try source(forID: from)
        let toSrc = try source(forID: to)
        mapper.buildMap(for: fromSrc, sourceID: from)
        mapper.buildMap(for: toSrc, sourceID: to)
        let result = mapper.convert(text: input, fromSourceID: from, toSourceID: to)
        XCTAssertEqual(
            result.lowercased(),
            expected.lowercased(),
            "EN '\(input)' typed in \(to) should be '\(expected)' (got '\(result)')",
            file: file,
            line: line
        )
    }

    // MARK: - Russian (EN ↔ RU)

    func test_RU_privet_from_EN_ghbdtn() throws {
        try assertConvert("ghbdtn", from: "com.apple.keylayout.US", to: "com.apple.keylayout.Russian", expected: "привет")
    }

    func test_RU_mir_from_EN_vbh() throws {
        try assertConvert("vbh", from: "com.apple.keylayout.US", to: "com.apple.keylayout.Russian", expected: "мир")
    }

    func test_RU_mama_from_EN_vfvf() throws {
        try assertConvert("vfvf", from: "com.apple.keylayout.US", to: "com.apple.keylayout.Russian", expected: "мама")
    }

    func test_RU_spasibo_from_EN_punct_chain() throws {
        try assertConvert("cgfcb,j", from: "com.apple.keylayout.US", to: "com.apple.keylayout.Russian", expected: "спасибо")
    }

    func test_RU_phrase_byl_li_ti_tut() throws {
        try assertConvert(",sk kb ns nen", from: "com.apple.keylayout.US", to: "com.apple.keylayout.Russian", expected: "был ли ты тут")
    }

    func test_RU_round_trip_preserves_text() throws {
        let from = "com.apple.keylayout.US"
        let to = "com.apple.keylayout.Russian"
        let fromSrc = try source(forID: from)
        let toSrc = try source(forID: to)
        mapper.buildMap(for: fromSrc, sourceID: from)
        mapper.buildMap(for: toSrc, sourceID: to)
        let original = "ghbdtn"
        let toRU = mapper.convert(text: original, fromSourceID: from, toSourceID: to)
        let backToEN = mapper.convert(text: toRU, fromSourceID: to, toSourceID: from)
        XCTAssertEqual(backToEN, original)
    }

    // MARK: - German (EN ↔ DE) — y/z swap is the headline difference

    func test_DE_zwei_from_EN_ywei() throws {
        try assertConvert("ywei", from: "com.apple.keylayout.US", to: "com.apple.keylayout.German", expected: "zwei")
    }

    func test_DE_zauber_from_EN_yauber() throws {
        try assertConvert("yauber", from: "com.apple.keylayout.US", to: "com.apple.keylayout.German", expected: "zauber")
    }

    func test_DE_yacht_from_EN_zacht() throws {
        // 'yacht' in DE is typed as zacht (Z key in DE = US Y position).
        try assertConvert("zacht", from: "com.apple.keylayout.US", to: "com.apple.keylayout.German", expected: "yacht")
    }

    // MARK: - French (EN ↔ FR) — AZERTY swaps a↔q and z↔w

    func test_FR_azur_from_EN_qwur() throws {
        try assertConvert("qwur", from: "com.apple.keylayout.US", to: "com.apple.keylayout.French", expected: "azur")
    }

    func test_FR_a_from_EN_q() throws {
        try assertConvert("q", from: "com.apple.keylayout.US", to: "com.apple.keylayout.French", expected: "a")
    }

    func test_FR_z_from_EN_w() throws {
        try assertConvert("w", from: "com.apple.keylayout.US", to: "com.apple.keylayout.French", expected: "z")
    }

    func test_FR_q_from_EN_a() throws {
        try assertConvert("a", from: "com.apple.keylayout.US", to: "com.apple.keylayout.French", expected: "q")
    }

    func test_FR_round_trip_preserves_text() throws {
        let from = "com.apple.keylayout.US"
        let to = "com.apple.keylayout.French"
        let fromSrc = try source(forID: from)
        let toSrc = try source(forID: to)
        mapper.buildMap(for: fromSrc, sourceID: from)
        mapper.buildMap(for: toSrc, sourceID: to)
        let original = "qwur"
        let toFR = mapper.convert(text: original, fromSourceID: from, toSourceID: to)
        let backToEN = mapper.convert(text: toFR, fromSourceID: to, toSourceID: from)
        XCTAssertEqual(backToEN, original)
    }

    // MARK: - Reverse direction (foreign → EN)

    func test_RU_to_EN_reverse_privet() throws {
        try assertConvert("привет", from: "com.apple.keylayout.Russian", to: "com.apple.keylayout.US", expected: "ghbdtn")
    }

    func test_UA_to_EN_reverse_juriy() throws {
        try assertConvert("юрій", from: "com.apple.keylayout.Ukrainian-PC", to: "com.apple.keylayout.US", expected: ".hsq")
    }
}
