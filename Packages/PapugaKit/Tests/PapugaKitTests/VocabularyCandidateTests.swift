import XCTest
@testable import PapugaKit

final class VocabularyCandidateTests: XCTestCase {
    func test_wordsPass() {
        for word in ["Supabase", "yoy", "Хрещатик", "п'ять", "Supabase,"] {
            XCTAssertTrue(TypingEngine.isVocabularyCandidate(word), word)
        }
    }

    func test_nonWordsFail() {
        for token in ["a", "abc123", "me@example.com", "https://x.io", "example.com", "#tag", "$HOME", "bcdfgh",
                      "averyveryverylongwordindeed"] {
            XCTAssertFalse(TypingEngine.isVocabularyCandidate(token), token)
        }
    }
}
