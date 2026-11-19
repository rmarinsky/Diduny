import XCTest
@testable import PapugaKit

final class TextSwitchSourceLayoutTests: XCTestCase {
    private func source(of text: String, system: String) -> String {
        TextSwitchSourceLayout.sourceLayout(of: text, among: ["en", "uk"], systemLayoutID: system) { character, id in
            let isCyrillic = character.unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) }
            return id == "uk" ? isCyrillic : character.isASCII
        }
    }

    func testTextDecidesTheSourceLayoutNotTheSystem() {
        // Latin gibberish selected while the keyboard already sits on Ukrainian.
        XCTAssertEqual(source(of: "htfkspedfnb", system: "uk"), "en")
        XCTAssertEqual(source(of: "руддщ", system: "en"), "uk")
        // Mostly-Latin selection with one already-correct Cyrillic word.
        XCTAssertEqual(source(of: "kjrfkmyj pfgecnb z d;t дома", system: "uk"), "en")
    }

    func testSystemLayoutWinsWhenTextAgreesOrSaysNothing() {
        XCTAssertEqual(source(of: "ghbdsn", system: "en"), "en")
        XCTAssertEqual(source(of: "123 ?!", system: "uk"), "uk")
        XCTAssertEqual(source(of: "ab вг", system: "uk"), "uk")
    }
}
