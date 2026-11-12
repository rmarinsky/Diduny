@testable import Diduny
import Testing

/// Soniox v6 spoken punctuation and edit commands in Diduny Cloud dictation.
struct SpokenCommandProcessorTests {
    @Test("English punctuation, with punctuation the model attached")
    func english() {
        #expect(SpokenCommandProcessor.apply("Hello, period. How are you question mark") == "Hello. How are you?")
        #expect(SpokenCommandProcessor.apply("Wait comma really exclamation point") == "Wait, really!")
        #expect(SpokenCommandProcessor.apply("It ends here Full Stop then more") == "It ends here. Then more")
        #expect(SpokenCommandProcessor.apply("Items colon milk") == "Items: milk")
    }

    @Test("Ukrainian punctuation; «крапка з комою» before «крапка» and «кома»")
    func ukrainian() {
        #expect(SpokenCommandProcessor.apply("Привіт кома як справи знак питання") == "Привіт, як справи?")
        #expect(SpokenCommandProcessor.apply("перше крапка з комою друге крапка") == "перше; друге.")
        #expect(SpokenCommandProcessor.apply("Список двокрапка молоко знак оклику") == "Список: молоко!")
        #expect(SpokenCommandProcessor.apply("Кінець Крапка далі") == "Кінець. Далі")
    }

    @Test("Polish punctuation and line breaks")
    func polish() {
        #expect(SpokenCommandProcessor.apply("Cześć przecinek co słychać kropka nowa linia dzięki wykrzyknik")
            == "Cześć, co słychać.\nDzięki!")
        #expect(SpokenCommandProcessor.apply("Lista dwukropek mleko znak zapytania") == "Lista: mleko?")
        #expect(SpokenCommandProcessor.apply("Raz nowy akapit dwa usuń to") == "Raz\n\n")
    }

    @Test("New line and new paragraph capitalize what follows")
    func lineBreaks() {
        #expect(SpokenCommandProcessor.apply("First line, new line. second line") == "First line\nSecond line")
        #expect(SpokenCommandProcessor.apply("перший новий абзац другий") == "перший\n\nДругий")
        #expect(SpokenCommandProcessor.apply("Done period new line next") == "Done.\nNext")
    }

    @Test("Scratch that at the start removes only the command")
    func scratchAtStart() {
        #expect(SpokenCommandProcessor.apply("Scratch that, hello there.") == "Hello there.")
    }

    @Test("Scratch that in the middle removes the sentence before it")
    func scratchInMiddle() {
        #expect(SpokenCommandProcessor.apply("First sentence. Second wrong scratch that third.") == "First sentence. Third.")
        #expect(SpokenCommandProcessor.apply("Привіт. Це помилка, видали це. Все добре.") == "Привіт. Все добре.")
        #expect(SpokenCommandProcessor.apply("Один. Два. скасуй це") == "Один.")
        #expect(SpokenCommandProcessor.apply("Line one\nline two scratch that line three") == "Line one\nLine three")
    }

    @Test("Command words inside other words stay")
    func wholeWordsOnly() {
        #expect(SpokenCommandProcessor.apply("The commander saw a periodic комар") == "The commander saw a periodic комар")
        #expect(SpokenCommandProcessor.apply("двокрапкаx and colonel") == "двокрапкаx and colonel")
    }

    @Test("A command word after a determiner is an ordinary noun")
    func afterDeterminer() {
        #expect(SpokenCommandProcessor.apply("For the period of time we wait period") == "For the period of time we wait.")
        #expect(SpokenCommandProcessor.apply("Тут ця кома зайва крапка") == "Тут ця кома зайва.")
    }

    @Test("Scratch that keeps a decimal number in the sentence it removes")
    func scratchKeepsDecimals() {
        #expect(SpokenCommandProcessor.apply("Amount is 3.14 scratch that use 3.15") == "Use 3.15")
    }

    @Test("Text without commands passes through unchanged")
    func passthrough() {
        let text = "Just a normal sentence, nothing to do here.\nSecond line."
        #expect(SpokenCommandProcessor.apply(text) == text)
        #expect(SpokenCommandProcessor.apply("") == "")
    }
}
