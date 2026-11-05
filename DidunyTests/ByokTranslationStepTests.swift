@testable import Diduny
import XCTest

final class ByokTranslationStepTests: XCTestCase {
    private let el = STTProviderID.elevenLabs
    private let elSelection = JobProviderSelection(providerID: STTProviderID.elevenLabs, modelID: "scribe_v2_realtime")

    private func context(key: Bool = true, translation: Bool) -> RoutingContext {
        RoutingContext(providersWithKey: key ? [STTProviderID.elevenLabs] : [], didunyTranslationAvailable: translation)
    }

    func testRunsPlanWhenSelectedAndRoutable() {
        let plan = ExecutionPlan(mode: .live, translation: .didunyStep)
        XCTAssertEqual(
            ByokTranslationStep.startDecision(providerID: el, selection: elSelection, plan: plan, context: context(translation: true), signedIn: true),
            .run(plan)
        )
    }

    func testDefaultSelectionKeepsExistingFlow() {
        XCTAssertEqual(
            ByokTranslationStep.startDecision(providerID: el, selection: .didunyCloud, plan: nil, context: context(translation: false), signedIn: false),
            .notSelected
        )
    }

    func testNoKeyKeepsExistingFlow() {
        XCTAssertEqual(
            ByokTranslationStep.startDecision(providerID: el, selection: elSelection, plan: nil, context: context(key: false, translation: false), signedIn: true),
            .notSelected
        )
    }

    func testSignedOutBlocksTranslation() {
        XCTAssertEqual(
            ByokTranslationStep.startDecision(providerID: el, selection: elSelection, plan: nil, context: context(translation: false), signedIn: false),
            .translationUnavailable(signedIn: false)
        )
    }

    func testNoQuotaBlocksTranslation() {
        XCTAssertEqual(
            ByokTranslationStep.startDecision(providerID: el, selection: elSelection, plan: nil, context: context(translation: false), signedIn: true),
            .translationUnavailable(signedIn: true)
        )
    }

    func testTranslateSendsTrimmedTextAndReturnsTranslation() async {
        let translator = StubTranslator(result: .success("Hello"))
        let result = await ByokTranslationStep.translate(" Привіт ", targetLanguage: "en", translator: translator)
        XCTAssertEqual(result.text, "Hello")
        XCTAssertTrue(result.translated)
        XCTAssertEqual(translator.calls, ["Привіт|auto|en"])
    }

    func testTranslateFailureKeepsOriginal() async {
        let translator = StubTranslator(result: .failure(URLError(.notConnectedToInternet)))
        let result = await ByokTranslationStep.translate("Привіт", targetLanguage: "en", translator: translator)
        XCTAssertEqual(result.text, "Привіт")
        XCTAssertFalse(result.translated)
    }

    func testEmptyTranscriptSkipsTranslation() async {
        let translator = StubTranslator(result: .success("x"))
        let result = await ByokTranslationStep.translate("  ", targetLanguage: "en", translator: translator)
        XCTAssertTrue(result.translated)
        XCTAssertTrue(translator.calls.isEmpty)
    }
}

private final class StubTranslator: TextTranslationProtocol, @unchecked Sendable {
    let result: Result<String, Error>
    private(set) var calls: [String] = []
    init(result: Result<String, Error>) { self.result = result }
    func translate(text: String, sourceLanguage: String, targetLanguage: String) async throws -> String {
        calls.append("\(text)|\(sourceLanguage)|\(targetLanguage)")
        return try result.get()
    }
}
