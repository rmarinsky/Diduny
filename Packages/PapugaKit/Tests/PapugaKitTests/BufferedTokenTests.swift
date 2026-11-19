import XCTest
@testable import PapugaKit

final class BufferedTokenTests: XCTestCase {
    func test_splitsProvisionalEdgePunctuationWithoutTouchingInternalPeriods() {
        let quoted = BufferedToken(rawText: "“можі?”", keyCodes: [1, 2, 3, 4, 5, 6, 7])
        XCTAssertEqual(quoted.leadingEdge, "“")
        XCTAssertEqual(quoted.core, "можі")
        XCTAssertEqual(quoted.trailingEdge, "?”")

        let domain = BufferedToken(rawText: "yoy.fyi,", keyCodes: [])
        XCTAssertEqual(domain.leadingEdge, "")
        XCTAssertEqual(domain.core, "yoy.fyi")
        XCTAssertEqual(domain.trailingEdge, ",")

        let hyphenated = BufferedToken(rawText: "-re-entry-", keyCodes: [])
        XCTAssertEqual(hyphenated.core, "-re-entry-")

        let apostrophe = BufferedToken(rawText: "don't", keyCodes: [])
        XCTAssertEqual(apostrophe.core, "don't")
    }

    func test_coreReplacementPreservesCommaPeriodAndSmartQuotes() {
        XCTAssertEqual(
            BufferedToken(rawText: "можі,", keyCodes: [])
                .replacementPlan(correctedCore: "може", boundary: " ", reason: .customRule)
                .renderedReplacement,
            "може,"
        )
        XCTAssertEqual(
            BufferedToken(rawText: "налащтуванні.", keyCodes: [])
                .replacementPlan(correctedCore: "налаштуванні", boundary: " ", reason: .sameLanguageSpelling)
                .renderedReplacement,
            "налаштуванні."
        )
        XCTAssertEqual(
            BufferedToken(rawText: "Unfortunatly,", keyCodes: [])
                .replacementPlan(correctedCore: "Unfortunately", boundary: " ", reason: .sameLanguageSpelling)
                .renderedReplacement,
            "Unfortunately,"
        )
        XCTAssertEqual(
            BufferedToken(rawText: "“можі?”", keyCodes: [])
                .replacementPlan(correctedCore: "може", boundary: " ", reason: .customRule)
                .renderedReplacement,
            "“може?”"
        )
    }

    func test_mutationAlwaysReplaysRenderedReplacementAndBoundary() {
        let plan = BufferedToken(rawText: "“можі?”", keyCodes: [])
            .replacementPlan(correctedCore: "може", boundary: "\n", reason: .customRule)

        XCTAssertEqual(plan.textToType, "“може?”\n")
        XCTAssertEqual(plan.characterCountToDelete, "“можі?”\n".count)

        let emptyBoundary = BufferedToken(rawText: "можі,", keyCodes: [])
            .replacementPlan(correctedCore: "може", boundary: "", reason: .customRule)
        XCTAssertEqual(emptyBoundary.textToType, "може, ")
    }

    func test_layoutSelectionConsumesPunctuationLookingKeysWhenOnlyFullMappingIsValid() {
        let semicolon = LayoutInterpretationPolicy.select(
            token: BufferedToken(rawText: "nfrj;", keyCodes: []),
            fullMapped: "також",
            coreMapped: "тако",
            fullIsValid: true,
            coreIsValid: false,
            boundary: " "
        )
        XCTAssertEqual(semicolon.replacementPlan?.renderedReplacement, "також")
        XCTAssertEqual(semicolon.replacementPlan?.interpretationReason, .layoutFullToken)
        XCTAssertEqual(semicolon.replacementPlan?.canCreateCoreRule, false)

        let leadingComma = LayoutInterpretationPolicy.select(
            token: BufferedToken(rawText: ",ed", keyCodes: []),
            fullMapped: "був",
            coreMapped: "ув",
            fullIsValid: true,
            coreIsValid: false,
            boundary: " "
        )
        XCTAssertEqual(leadingComma.replacementPlan?.renderedReplacement, "був")
        XCTAssertEqual(leadingComma.replacementPlan?.canCreateCoreRule, false)
    }

    func test_layoutSelectionPreservesPunctuationWhenOnlyCoreMappingIsValid() {
        let decision = LayoutInterpretationPolicy.select(
            token: BufferedToken(rawText: "ghbdsn,", keyCodes: []),
            fullMapped: "привітб",
            coreMapped: "привіт",
            fullIsValid: false,
            coreIsValid: true,
            boundary: " "
        )

        XCTAssertEqual(decision.replacementPlan?.correctedCore, "привіт")
        XCTAssertEqual(decision.replacementPlan?.preservedTrailingPunctuation, ",")
        XCTAssertEqual(decision.replacementPlan?.renderedReplacement, "привіт,")
        XCTAssertEqual(decision.replacementPlan?.interpretationReason, .layoutCorePreservingEdges)
        XCTAssertEqual(decision.replacementPlan?.canCreateCoreRule, true)
    }

    func test_layoutSelectionIsSuggestionOnlyWhenBothDifferentInterpretationsAreValid() {
        let decision = LayoutInterpretationPolicy.select(
            token: BufferedToken(rawText: "word,", keyCodes: []),
            fullMapped: "повне",
            coreMapped: "ядро",
            fullIsValid: true,
            coreIsValid: true,
            boundary: " "
        )

        XCTAssertTrue(decision.isSuggestionOnly)
        XCTAssertNil(decision.replacementPlan)
        XCTAssertEqual(decision.suggestions.map(\.renderedReplacement), ["повне", "ядро,"])
    }

    func test_layoutSelectionRejectsWhenNeitherInterpretationIsValid() {
        let decision = LayoutInterpretationPolicy.select(
            token: BufferedToken(rawText: "word,", keyCodes: []),
            fullMapped: "x",
            coreMapped: "y",
            fullIsValid: false,
            coreIsValid: false,
            boundary: " "
        )

        XCTAssertTrue(decision.isRejected)
        XCTAssertNil(decision.replacementPlan)
    }

    func test_customRuleMatchesCoreAcrossPunctuationVariants() {
        let rule = CustomAutoReplaceRule(source: "можі", target: "може")

        XCTAssertTrue(rule.matches("можі,"))
        XCTAssertTrue(rule.matches(BufferedToken(rawText: "можі", keyCodes: [])))
        XCTAssertTrue(rule.matches(BufferedToken(rawText: "можі,", keyCodes: [])))
        XCTAssertTrue(rule.matches(BufferedToken(rawText: "“можі?”", keyCodes: [])))

    }

    func test_fullTokenRuleConsumesLayoutKeyThatLooksLikePunctuation() {
        let rule = CustomAutoReplaceRule(
            source: "nfrj;",
            target: "також",
            matchesFullToken: true
        )

        XCTAssertTrue(rule.matches("nfrj;"))
        XCTAssertFalse(rule.matches("nfrj"))
        XCTAssertFalse(rule.matches("nfrj;,"))
    }

    func test_coreAndFullTokenRulesHaveDistinctMatchScopes() {
        let core = CustomAutoReplaceRule(source: "nfrj", target: "core")
        let exact = CustomAutoReplaceRule(
            source: "nfrj;",
            target: "також",
            matchesFullToken: true
        )

        XCTAssertFalse(core.hasSameMatchScope(as: exact))
        XCTAssertTrue(exact.hasSameMatchScope(as: exact))
    }

    func test_legacyRuleWithoutMatchScopeStillDecodesAsCoreRule() throws {
        let encoded = try JSONEncoder().encode(CustomAutoReplaceRule(source: "можі", target: "може"))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "matchesFullToken")
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let rule = try JSONDecoder().decode(CustomAutoReplaceRule.self, from: legacyData)

        XCTAssertNil(rule.matchesFullToken)
        XCTAssertTrue(rule.matches("можі,"))
    }

    func test_allowlistProtectsBareAndPunctuatedVariantsThroughOneCoreEntry() {
        let allowlist = ["yoy"]

        XCTAssertTrue(AutoFixDecision.isInAllowlist(BufferedToken(rawText: "yoy", keyCodes: []).core, allowlist: allowlist))
        XCTAssertTrue(AutoFixDecision.isInAllowlist(BufferedToken(rawText: "yoy,", keyCodes: []).core, allowlist: allowlist))
        XCTAssertTrue(AutoFixDecision.isInAllowlist(BufferedToken(rawText: "yoy?", keyCodes: []).core, allowlist: allowlist))
    }
}
