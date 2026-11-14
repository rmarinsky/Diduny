import XCTest
import Carbon.HIToolbox
@testable import PapugaKit

final class CharacterMapperTests: XCTestCase {
    func test_deadKeySequenceConvertsToACompleteAccentedCharacter() throws {
        let (from, to) = try buildMaps(from: "com.apple.keylayout.US", to: "com.apple.keylayout.USInternational-PC")
        XCTAssertEqual(mapper.convert(text: "'e", fromSourceID: from, toSourceID: to), "é")
        XCTAssertEqual(mapper.convert(text: "é", fromSourceID: to, toSourceID: from), "'e")
    }

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

    private func buildMaps(from: String, to: String) throws -> (from: String, to: String) {
        let fromSrc = try source(forID: from)
        let toSrc = try source(forID: to)
        mapper.buildMap(for: fromSrc, sourceID: from)
        mapper.buildMap(for: toSrc, sourceID: to)
        return (from, to)
    }

    func test_dot_hsq_in_EN_maps_to_yuriy_in_UkrainianPC() throws {
        let (from, to) = try buildMaps(from: "com.apple.keylayout.US", to: "com.apple.keylayout.Ukrainian-PC")
        let result = mapper.convert(text: ".hsq", fromSourceID: from, toSourceID: to)
        XCTAssertEqual(result.lowercased(), "юрій", "EN '.hsq' typed in Ukrainian-PC should be 'юрій' (got '\(result)')")
    }

    func test_comma_ed_in_EN_maps_to_buv_in_UkrainianPC() throws {
        let (from, to) = try buildMaps(from: "com.apple.keylayout.US", to: "com.apple.keylayout.Ukrainian-PC")
        let result = mapper.convert(text: ",ed", fromSourceID: from, toSourceID: to)
        XCTAssertEqual(result.lowercased(), "був", "EN ',ed' typed in Ukrainian-PC should be 'був' (got '\(result)')")
    }

    func test_nb_in_EN_maps_to_ty_in_UkrainianPC() throws {
        let (from, to) = try buildMaps(from: "com.apple.keylayout.US", to: "com.apple.keylayout.Ukrainian-PC")
        let result = mapper.convert(text: "nb", fromSourceID: from, toSourceID: to)
        XCTAssertEqual(result.lowercased(), "ти", "EN 'nb' typed in Ukrainian-PC should be 'ти' (got '\(result)')")
    }

    func test_nen_in_EN_maps_to_tut_in_UkrainianPC() throws {
        let (from, to) = try buildMaps(from: "com.apple.keylayout.US", to: "com.apple.keylayout.Ukrainian-PC")
        let result = mapper.convert(text: "nen", fromSourceID: from, toSourceID: to)
        XCTAssertEqual(result.lowercased(), "тут", "EN 'nen' typed in Ukrainian-PC should be 'тут' (got '\(result)')")
    }

    func test_full_phrase_buv_ti_tut_in_UkrainianPC() throws {
        let (from, to) = try buildMaps(from: "com.apple.keylayout.US", to: "com.apple.keylayout.Ukrainian-PC")
        let result = mapper.convert(text: ",ed nb nen", fromSourceID: from, toSourceID: to)
        XCTAssertEqual(result.lowercased(), "був ти тут", "EN ',ed nb nen' typed in Ukrainian-PC should be 'був ти тут' (got '\(result)')")
    }

    func test_word_with_semicolon_in_middle_maps_correctly() throws {
        // Regression: ';' in EN is the key for 'ж' in Ukrainian-PC. A word like
        // 'df;kbdj' typed by a user who meant to write 'важливо' must map cleanly,
        // and the buffer must NOT split at the semicolon.
        let (from, to) = try buildMaps(from: "com.apple.keylayout.US", to: "com.apple.keylayout.Ukrainian-PC")
        let result = mapper.convert(text: "df;kbdj", fromSourceID: from, toSourceID: to)
        XCTAssertEqual(result.lowercased(), "важливо", "EN 'df;kbdj' should map to 'важливо' (got '\(result)')")
    }

    func test_terminal_semicolon_can_be_layout_letter() throws {
        let (from, to) = try buildMaps(from: "com.apple.keylayout.US", to: "com.apple.keylayout.Ukrainian-PC")
        let result = mapper.convert(text: "nfrj;", fromSourceID: from, toSourceID: to)
        XCTAssertEqual(result.lowercased(), "також")
    }

    func test_fullAndCoreMappingsSupportPunctuationInterpretation() throws {
        let (from, to) = try buildMaps(from: "com.apple.keylayout.US", to: "com.apple.keylayout.Ukrainian-PC")
        let token = BufferedToken(rawText: "ghbdsn,", keyCodes: [])

        XCTAssertEqual(
            mapper.convert(text: token.rawText, fromSourceID: from, toSourceID: to).lowercased(),
            "привітб"
        )
        XCTAssertEqual(
            mapper.convert(text: token.core, fromSourceID: from, toSourceID: to).lowercased(),
            "привіт"
        )
    }

    func test_round_trip_preserves_text() throws {
        let (from, to) = try buildMaps(from: "com.apple.keylayout.US", to: "com.apple.keylayout.Ukrainian-PC")
        let original = "hello"
        let toUA = mapper.convert(text: original, fromSourceID: from, toSourceID: to)
        let backToEN = mapper.convert(text: toUA, fromSourceID: to, toSourceID: from)
        XCTAssertEqual(backToEN.lowercased(), original.lowercased())
    }

    func test_real_english_word_unchanged_when_target_layout_is_english() throws {
        let (from, _) = try buildMaps(from: "com.apple.keylayout.US", to: "com.apple.keylayout.US")
        let result = mapper.convert(text: "hello", fromSourceID: from, toSourceID: from)
        XCTAssertEqual(result, "hello")
    }

    func test_unmappable_chars_pass_through() throws {
        let (from, to) = try buildMaps(from: "com.apple.keylayout.US", to: "com.apple.keylayout.Ukrainian-PC")
        let result = mapper.convert(text: "abc 123", fromSourceID: from, toSourceID: to)
        XCTAssertTrue(result.contains("123"), "digits should pass through unchanged: got '\(result)')")
    }
}
