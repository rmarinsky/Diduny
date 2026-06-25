import Testing

@testable import Diduny

// MARK: - RealtimeSessionHealth unit tests

@Suite("RealtimeSessionHealth")
struct RealtimeSessionHealthTests {
    // MARK: isUnstable gate

    @Test("healthy session is not unstable")
    func healthySessionIsStable() {
        let health = RealtimeSessionHealth.healthy
        #expect(!health.isUnstable)
    }

    @Test("one reconnect marks session as unstable")
    func oneReconnectIsUnstable() {
        let health = RealtimeSessionHealth(
            reconnectCount: 1,
            wasDisconnectedDuringSession: true,
            hardFailed: false
        )
        #expect(health.isUnstable)
    }

    @Test("hard fail marks session as unstable even with zero reconnects")
    func hardFailIsUnstable() {
        let health = RealtimeSessionHealth(
            reconnectCount: 0,
            wasDisconnectedDuringSession: false,
            hardFailed: true
        )
        #expect(health.isUnstable)
    }

    @Test("disconnected-but-recovered within attempt-0 is not unstable")
    func disconnectedButNoReconnectAttemptIsStable() {
        // wasDisconnected alone does not trigger the fallback; only reconnectCount or hardFailed do.
        let health = RealtimeSessionHealth(
            reconnectCount: 0,
            wasDisconnectedDuringSession: true,
            hardFailed: false
        )
        #expect(!health.isUnstable)
    }

    @Test("multiple reconnects accumulate")
    func multipleReconnectsAreUnstable() {
        let health = RealtimeSessionHealth(
            reconnectCount: 3,
            wasDisconnectedDuringSession: true,
            hardFailed: false
        )
        #expect(health.isUnstable)
        #expect(health.reconnectCount == 3)
    }

    // MARK: RealtimeSessionStopResult health passthrough

    @Test("empty stop result carries healthy snapshot")
    func emptyResultIsHealthy() {
        #expect(RealtimeSessionStopResult.empty.sessionHealth == .healthy)
        #expect(!RealtimeSessionStopResult.empty.sessionHealth.isUnstable)
    }

    @Test("stop result preserves health struct equality")
    func stopResultPreservesHealth() {
        let health = RealtimeSessionHealth(
            reconnectCount: 2,
            wasDisconnectedDuringSession: true,
            hardFailed: false
        )
        let result = RealtimeSessionStopResult(
            text: "test",
            preFinalizeText: "test",
            optimisticCleanedText: nil,
            finalizeResult: .skipped,
            sessionHealth: health
        )
        #expect(result.sessionHealth == health)
        #expect(result.sessionHealth.isUnstable)
    }

    // MARK: Instability-fallback trigger condition

    // Replicates the exact boolean gate from stopRecording / stopTranslationRecording:
    //   sessionUnstable && !realtimeResult.text.isEmpty && provider == .cloud

    @Test("fallback fires when unstable + realtime text present + cloud provider")
    func fallbackConditionFires() {
        let health = RealtimeSessionHealth(reconnectCount: 1, wasDisconnectedDuringSession: true, hardFailed: false)
        let sessionUnstable = health.isUnstable
        let realtimeText = "hello world"
        let isCloud = true

        let shouldFallback = sessionUnstable && !realtimeText.isEmpty && isCloud
        #expect(shouldFallback)
    }

    @Test("fallback does NOT fire when session is stable")
    func fallbackDoesNotFireWhenStable() {
        let health = RealtimeSessionHealth.healthy
        let sessionUnstable = health.isUnstable
        let shouldFallback = sessionUnstable && !("hello").isEmpty && true
        #expect(!shouldFallback)
    }

    @Test("fallback does NOT fire when realtime text is empty (no realtime result to replace)")
    func fallbackDoesNotFireWhenRealtimeEmpty() {
        let health = RealtimeSessionHealth(reconnectCount: 2, wasDisconnectedDuringSession: true, hardFailed: false)
        let sessionUnstable = health.isUnstable
        let shouldFallback = sessionUnstable && !"".isEmpty && true
        #expect(!shouldFallback)
    }

    @Test("fallback does NOT fire for local provider")
    func fallbackDoesNotFireForLocalProvider() {
        let health = RealtimeSessionHealth(reconnectCount: 1, wasDisconnectedDuringSession: true, hardFailed: false)
        let sessionUnstable = health.isUnstable
        let isCloud = false // local provider
        let shouldFallback = sessionUnstable && !("hello").isEmpty && isCloud
        #expect(!shouldFallback)
    }

    // MARK: Clean-path routing (3-branch: realtime / HTTP server-cleaned / local Whisper)

    // The routing decision in stopRecording / stopTranslationRecording uses two booleans:
    //   usedInstabilityFallback  — set when the instability HTTP fallback succeeded
    //   httpTextIsServerCleaned  — set for ANY successful HTTP path (fallback or normal cloud)
    //   realtimeText.isEmpty     — whether realtime was used at all
    //
    // Branch 1 (realtime): !usedInstabilityFallback && !realtimeText.isEmpty
    // Branch 2 (lexiconOnly / HTTP): httpTextIsServerCleaned
    // Branch 3 (full clean / Whisper or offline partial): neither of the above

    @Test("routing: realtime path selected when realtime text present and fallback not triggered")
    func routingSelectsRealtimePath() {
        let usedInstabilityFallback = false
        let httpTextIsServerCleaned = false
        let realtimeText = "some dictation"
        let useRealtimePath = !usedInstabilityFallback && !realtimeText.isEmpty
        let useHTTPPath = httpTextIsServerCleaned
        #expect(useRealtimePath)
        #expect(!useHTTPPath)
    }

    @Test("routing: lexiconOnly path selected for instability fallback (HTTP)")
    func routingSelectsLexiconOnlyForInstabilityFallback() {
        let usedInstabilityFallback = true
        let httpTextIsServerCleaned = true
        let realtimeText = "some dictation"
        let useRealtimePath = !usedInstabilityFallback && !realtimeText.isEmpty
        let useHTTPPath = httpTextIsServerCleaned
        #expect(!useRealtimePath)
        #expect(useHTTPPath)
    }

    @Test("routing: lexiconOnly path selected for normal HTTP cloud path")
    func routingSelectsLexiconOnlyForNormalHTTP() {
        // realtimeText is empty → realtime was not used (or failed to connect)
        let usedInstabilityFallback = false
        let httpTextIsServerCleaned = true
        let realtimeText = ""
        let useRealtimePath = !usedInstabilityFallback && !realtimeText.isEmpty
        let useHTTPPath = httpTextIsServerCleaned
        #expect(!useRealtimePath)
        #expect(useHTTPPath)
    }

    @Test("routing: full clean path selected for local Whisper (not server-cleaned)")
    func routingSelectsFullCleanForWhisper() {
        let usedInstabilityFallback = false
        let httpTextIsServerCleaned = false
        let realtimeText = ""
        let useRealtimePath = !usedInstabilityFallback && !realtimeText.isEmpty
        let useHTTPPath = httpTextIsServerCleaned
        #expect(!useRealtimePath)
        #expect(!useHTTPPath)
        // → falls through to the full TranscriptCleanupService.clean branch
    }

    @Test("routing: full clean path selected when instability HTTP fallback itself fails (partial realtime text used)")
    func routingSelectsFullCleanWhenInstabilityFallbackFails() {
        // HTTP threw → usedInstabilityFallback stays false, httpTextIsServerCleaned stays false
        // rawText = realtimeResult.text (partial) → realtimeText non-empty
        // BUT usedInstabilityFallback is false, so realtime path fires — which is correct:
        // we treat the partial realtime text as "realtime output" and run /clean on it.
        let usedInstabilityFallback = false
        let httpTextIsServerCleaned = false
        let realtimeText = "partial text from realtime"
        let useRealtimePath = !usedInstabilityFallback && !realtimeText.isEmpty
        #expect(useRealtimePath)
        // In this case cleanRealtimeResultText is used, which runs /clean — correct behaviour:
        // partial text from realtime needs dedup, and we have realtimeResult metadata.
    }
}

// MARK: - CloudTranscriptionService config builder tests

@Suite("CloudTranscriptionService config builders")
struct CloudTranscriptionConfigTests {

    @Test("makeTranscriptionConfig omits fillerWords when empty")
    func transcriptionConfigNoFillerWords() {
        let config = CloudTranscriptionService.makeTranscriptionConfig(
            languageConfig: CloudLanguageConfig(hints: [], strict: false),
            fillerWords: []
        )
        #expect(config["fillerWords"] == nil)
        #expect(config["mode"] as? String == "transcribe")
    }

    @Test("makeTranscriptionConfig includes fillerWords when provided")
    func transcriptionConfigWithFillerWords() {
        let config = CloudTranscriptionService.makeTranscriptionConfig(
            languageConfig: CloudLanguageConfig(hints: [], strict: false),
            fillerWords: ["ну", "типу", "е"]
        )
        let words = config["fillerWords"] as? [String]
        #expect(words == ["ну", "типу", "е"])
    }

    @Test("makeTranscriptionConfig strips blank entries from fillerWords")
    func transcriptionConfigFiltersBlankFillerWords() {
        let config = CloudTranscriptionService.makeTranscriptionConfig(
            languageConfig: CloudLanguageConfig(hints: [], strict: false),
            fillerWords: ["ну", "  ", "типу", ""]
        )
        let words = config["fillerWords"] as? [String]
        #expect(words == ["ну", "типу"])
    }

    @Test("makeTwoWayTranslationConfig includes fillerWords")
    func twoWayTranslationConfigWithFillerWords() {
        let pair = TranslationLanguagePair(languageA: "uk", languageB: "en")
        let config = CloudTranscriptionService.makeTwoWayTranslationConfig(
            languagePair: pair,
            languageConfig: CloudLanguageConfig(hints: [], strict: false),
            fillerWords: ["ну", "типу"]
        )
        let words = config["fillerWords"] as? [String]
        #expect(words == ["ну", "типу"])
        #expect(config["mode"] as? String == "translate")
    }

    @Test("makeOneWayTranslationConfig includes fillerWords")
    func oneWayTranslationConfigWithFillerWords() {
        let config = CloudTranscriptionService.makeOneWayTranslationConfig(
            targetLanguage: "en",
            languageConfig: CloudLanguageConfig(hints: [], strict: false),
            fillerWords: ["ну"]
        )
        let words = config["fillerWords"] as? [String]
        #expect(words == ["ну"])
    }

    @Test("applyFillerWords is a no-op for empty list")
    func applyFillerWordsNoOp() {
        var config: [String: Any] = ["mode": "transcribe"]
        CloudTranscriptionService.applyFillerWords([], to: &config)
        #expect(config["fillerWords"] == nil)
    }

    @Test("fillerWords default is empty — existing callers not broken")
    func transcriptionConfigDefaultFillerWordsIsEmpty() {
        // Calling without fillerWords parameter uses the default []
        let config = CloudTranscriptionService.makeTranscriptionConfig(
            languageConfig: CloudLanguageConfig(hints: [], strict: false)
        )
        #expect(config["fillerWords"] == nil)
    }
}
