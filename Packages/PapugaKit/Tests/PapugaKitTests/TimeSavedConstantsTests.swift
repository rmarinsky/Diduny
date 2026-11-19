import XCTest
@testable import PapugaKit

final class TimeSavedConstantsTests: XCTestCase {
    func testSanitizesTypingSpeedForEstimate() {
        XCTAssertEqual(Constants.sanitizedTypingWordsPerMinute(.infinity), 40)
        XCTAssertEqual(Constants.sanitizedTypingWordsPerMinute(4), 10)
        XCTAssertEqual(Constants.sanitizedTypingWordsPerMinute(200), 160)
        XCTAssertEqual(Constants.sanitizedTypingWordsPerMinute(42.4), 42)
    }

    func testSecondsSavedUsesMeasuredTypingSpeed() {
        XCTAssertEqual(Constants.secondsSaved(words: 3, measuredTypingWPM: 60), 5)
        XCTAssertEqual(Constants.secondsSaved(words: 0, measuredTypingWPM: 60), 3)
    }

    func testAggregateEstimateMatchesOverheadPlusTypingTime() {
        XCTAssertEqual(Constants.estimatedSecondsSaved(replacementCount: 2, totalWords: 5, measuredTypingWPM: 30), 14)
        XCTAssertEqual(Constants.estimatedSecondsSaved(replacementCount: 0, totalWords: 5, measuredTypingWPM: 30), 0)
    }
}
