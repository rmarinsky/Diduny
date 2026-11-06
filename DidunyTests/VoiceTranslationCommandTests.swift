@testable import Diduny
import XCTest

final class VoiceTranslationCommandTests: XCTestCase {
    private let allLanguages = Set(SupportedLanguage.cloudLanguages.map(\.code))

    private func detect(
        _ text: String,
        position: VoiceTranslationCommandPosition = .startAndEnd,
        languages: Set<String>? = nil
    ) -> VoiceTranslationCommand? {
        VoiceTranslationCommand.detect(in: text, position: position, languages: languages ?? allLanguages)
    }

    func test_trailingEnglishCommand() throws {
        let command = try XCTUnwrap(detect("Привіт, Марто. Зустріч у вівторок. Translate into Spanish."))
        XCTAssertEqual(command.targetLanguage, "es")
        XCTAssertEqual(command.commandText, "Translate into Spanish")
        XCTAssertEqual(command.remainingText, "Привіт, Марто. Зустріч у вівторок.")
        XCTAssertEqual(command.position, .trailing)
    }

    func test_trailingCommandWithoutPunctuationBeforeIt() throws {
        let command = try XCTUnwrap(detect("Демо в четвер, translate it into English please"))
        XCTAssertEqual(command.targetLanguage, "en")
        XCTAssertEqual(command.remainingText, "Демо в четвер")
    }

    func test_returnItToTheUkrainianLanguage() throws {
        let command = try XCTUnwrap(detect("See you on Monday. Return it to the Ukrainian language."))
        XCTAssertEqual(command.targetLanguage, "uk")
        XCTAssertEqual(command.remainingText, "See you on Monday.")
    }

    func test_ukrainianCommands() {
        XCTAssertEqual(detect("Зустріч завтра. Переклади на іспанську.")?.targetLanguage, "es")
        XCTAssertEqual(detect("Зустріч завтра. Переклади іспанською мовою")?.targetLanguage, "es")
        XCTAssertEqual(detect("See you tomorrow. Українською.")?.targetLanguage, "uk")
        XCTAssertEqual(detect("See you tomorrow, назад українською")?.targetLanguage, "uk")
    }

    func test_leadingCommand() throws {
        let command = try XCTUnwrap(detect("In English. 1886 рік, Нью-Йорк."))
        XCTAssertEqual(command.targetLanguage, "en")
        XCTAssertEqual(command.commandText, "In English")
        XCTAssertEqual(command.remainingText, "1886 рік, Нью-Йорк.")
        XCTAssertEqual(command.position, .leading)
    }

    func test_leadingCommandIgnoredWhenListeningAtEndOnly() {
        XCTAssertNil(detect("In English. 1886 рік, Нью-Йорк.", position: .endOnly))
    }

    func test_endWinsAndBothCommandsAreRemoved() throws {
        let command = try XCTUnwrap(detect("In English. Зустріч завтра. Translate into German."))
        XCTAssertEqual(command.targetLanguage, "de")
        XCTAssertEqual(command.remainingText, "Зустріч завтра.")
    }

    func test_commandInTheMiddleIsContent() {
        XCTAssertNil(detect("Ми домовились, що translate into Spanish зробимо завтра."))
        XCTAssertNil(detect("Він сказав in English і пішов далі"))
    }

    func test_wordsAfterTheCommandMakeItContent() {
        XCTAssertNil(detect("Зустріч завтра. Translate into Spanish. Ні, лишаємо так"))
    }

    func test_bareLanguageNameIsNotACommand() {
        XCTAssertNil(detect("We are learning Spanish"))
        XCTAssertNil(detect("I talked to Spanish"))
    }

    func test_languageOutsideAllowedSetIsNotACommand() {
        XCTAssertNil(detect("Зустріч завтра. Translate into Spanish.", languages: ["en", "uk"]))
        XCTAssertEqual(detect("Зустріч завтра. In English.", languages: ["en", "uk"])?.targetLanguage, "en")
    }

    func test_nativeLanguageName() {
        XCTAssertEqual(detect("Nos vemos mañana. Translate into español")?.targetLanguage, "es")
    }

    // MARK: - WP-53 "Anywhere"

    func test_T5LA06_anywhereFindsTheCommandInTheMiddleAndCutsIt() throws {
        let command = try XCTUnwrap(detect("Hello team, translate into Polish, see you on Friday.", position: .anywhere))
        XCTAssertEqual(command.targetLanguage, "pl")
        XCTAssertEqual(command.commandText, "translate into Polish")
        XCTAssertEqual(command.remainingText, "Hello team, see you on Friday.")
        XCTAssertEqual(command.position, .middle)

        let ukrainian = try XCTUnwrap(detect("Привіт, переклади на польську, побачимось у п'ятницю", position: .anywhere))
        XCTAssertEqual(ukrainian.targetLanguage, "pl")
        XCTAssertEqual(ukrainian.remainingText, "Привіт, побачимось у п'ятницю")
    }

    func test_T5LA06_anywhereStillCutsTheHeadCommand() throws {
        let command = try XCTUnwrap(detect("please translate into Polish this text", position: .anywhere))
        XCTAssertEqual(command.targetLanguage, "pl")
        XCTAssertEqual(command.remainingText, "this text")
    }

    /// 05 §2.3 risk, pending Roman: "to translate into X" in a sentence stays content.
    func test_T5LA06_anywhereIgnoresAnInfinitiveInASentence() {
        XCTAssertNil(detect("we need to translate into Polish by Friday", position: .anywhere))
    }

    func test_T5LA06_anywhereNeedsAVerbInTheMiddle() {
        XCTAssertNil(detect("Він сказав in English і пішов далі", position: .anywhere))
        XCTAssertNil(detect("We talked about Polish грамматику today", position: .anywhere))
    }

    func test_T5LA07_endWinsOverTheMiddle() throws {
        let command = try XCTUnwrap(
            detect("Hi, translate into Polish, bye. Translate into German.", position: .anywhere)
        )
        XCTAssertEqual(command.targetLanguage, "de")
        XCTAssertEqual(command.position, .trailing)
    }

    func test_T5LA07_existingPositionsIgnoreTheMiddle() {
        let text = "Hello team, translate into Polish, see you on Friday."
        XCTAssertNil(detect(text, position: .startAndEnd))
        XCTAssertNil(detect(text, position: .endOnly))
    }
}
