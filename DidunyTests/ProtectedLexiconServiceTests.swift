import XCTest
@testable import Diduny

final class ProtectedLexiconServiceTests: XCTestCase {
    func test_promptBuilder_appendsLexiconHintsWithoutDroppingUserPrompt() {
        let prompt = ProtectedLexiconPromptBuilder.mergedPrompt(
            userPrompt: "Prefer short punctuation.",
            language: "en"
        )

        XCTAssertNotNil(prompt)
        XCTAssertTrue(prompt?.contains("Prefer short punctuation.") == true)
        XCTAssertTrue(prompt?.contains("Payoneer") == true)
        XCTAssertTrue(prompt?.contains("GitHub") == true)
    }

    func test_postprocessTranscript_normalizesHighConfidenceAliases() {
        let text = "Please open git hub and check pay one ear account."
        let normalized = ProtectedLexiconService.shared.postprocessTranscript(text)

        XCTAssertEqual(normalized, "Please open GitHub and check Payoneer account.")
    }

    func test_postprocessTranscript_preservesUnrelatedText() {
        let text = "This transcript has no protected aliases."
        let normalized = ProtectedLexiconService.shared.postprocessTranscript(text)

        XCTAssertEqual(normalized, text)
    }
}
