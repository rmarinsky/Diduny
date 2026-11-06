@testable import Diduny
import Foundation
import Testing

@MainActor
@Suite("Local models table model (T4-ROW, T4-FIL, T4-SORT, T4-CELL)")
struct ModelTableModelTests {
    private func make(
        whisper: FakeWhisperModelStore? = nil,
        parakeet: FakeParakeetModelStore? = nil,
        apple: Bool = true
    ) -> LocalModelsModel {
        LocalModelsModel(
            whisper: whisper ?? FakeWhisperModelStore(),
            parakeet: parakeet ?? FakeParakeetModelStore(),
            isAppleSpeechAvailable: apple,
            yourLanguages: ["uk", "en"]
        )
    }

    private func row(_ model: LocalModelsModel, _ id: String) throws -> LocalModelRow {
        try #require(model.rows.first { $0.id == id })
    }

    private let turbo = "ggml-large-v3-turbo"
    private let multilingualNotTurbo = ["ggml-tiny", "ggml-base", "ggml-small", "ggml-medium", "ggml-large-v2", "ggml-large-v3"]
    private let englishOnly = ["ggml-tiny.en", "ggml-base.en", "ggml-small.en", "ggml-medium.en"]

    // MARK: Actions cell

    @Test("T4-ROW-01 actions cell state machine, Whisper")
    func whisperStateMachine() throws {
        let whisper = FakeWhisperModelStore()
        let model = make(whisper: whisper)
        let r = try row(model, turbo)
        #expect(model.action(for: r) == .download)
        model.download(r)
        #expect(model.action(for: r) == .downloading(percent: 0))
        whisper.progress(turbo, 0.4)
        #expect(model.action(for: r) == .downloading(percent: 40))
        whisper.complete(turbo)
        whisper.selectedModelName = "ggml-tiny"
        #expect(model.action(for: r) == .use)
        model.use(r)
        #expect(model.action(for: r) == .active)
        model.askToDelete(r)
        #expect(model.action(for: r) == .askingDelete(size: "1.5 GB"))
        model.keep()
        #expect(model.action(for: r) == .active)
        model.askToDelete(r)
        model.confirmDelete(r)
        #expect(model.action(for: r) == .download)
        #expect(whisper.deleted == [turbo])
    }

    @Test("T4-ROW-01 actions cell state machine, Parakeet")
    func parakeetStateMachine() throws {
        let parakeet = FakeParakeetModelStore(.notDownloaded)
        let model = make(parakeet: parakeet)
        let r = try row(model, "parakeet-v3")
        #expect(model.action(for: r) == .download)
        model.download(r)
        parakeet.state = .downloading(0.4)
        #expect(model.action(for: r) == .downloading(percent: 40))
        parakeet.state = .downloaded
        #expect(model.action(for: r) == .ready)
        #expect(model.action(for: r).showsTrash)
        model.askToDelete(r)
        #expect(model.action(for: r) == .askingDelete(size: "480 MB"))
        model.confirmDelete(r)
        #expect(parakeet.deleteCount == 1)
        #expect(model.action(for: r) == .download)
    }

    @Test("T4-ROW-02 only one row asks to delete")
    func oneQuestion() throws {
        let model = make(whisper: FakeWhisperModelStore(["ggml-tiny": .downloaded, turbo: .downloaded], active: turbo))
        let tiny = try row(model, "ggml-tiny"), large = try row(model, turbo)
        model.askToDelete(tiny)
        model.askToDelete(large)
        #expect(model.action(for: tiny) == .use)
        #expect(model.action(for: large) == .askingDelete(size: "1.5 GB"))
        // Confirming the row that no longer asks does nothing.
        model.confirmDelete(tiny)
        #expect(model.action(for: tiny) == .use)
    }

    @Test("T4-ROW-03 Escape and leaving the page count as Keep")
    func keepOnEscape() throws {
        let whisper = FakeWhisperModelStore(["ggml-tiny": .downloaded])
        let model = make(whisper: whisper)
        let tiny = try row(model, "ggml-tiny")
        model.askToDelete(tiny)
        model.keep()
        #expect(model.action(for: tiny) == .use)
        #expect(whisper.deleted.isEmpty)
    }

    @Test("T4-ROW-04 Use makes one Whisper model Active")
    func useOne() throws {
        let whisper = FakeWhisperModelStore(["ggml-tiny": .downloaded, turbo: .downloaded], active: turbo)
        let model = make(whisper: whisper)
        model.use(try row(model, "ggml-tiny"))
        #expect(model.action(for: try row(model, "ggml-tiny")) == .active)
        #expect(model.action(for: try row(model, turbo)) == .use)
        #expect(whisper.selectedModelName == "ggml-tiny")
    }

    @Test("T4-ROW-05 deleting the Active model leaves none Active")
    func deleteActive() throws {
        let whisper = FakeWhisperModelStore(["ggml-tiny": .downloaded, turbo: .downloaded], active: turbo)
        let model = make(whisper: whisper)
        let large = try row(model, turbo)
        model.askToDelete(large)
        model.confirmDelete(large)
        #expect(whisper.selectedModelName == "")
        #expect(model.action(for: try row(model, "ggml-tiny")) == .use)
    }

    @Test("T4-ROW-06 Cancel stops a download")
    func cancelWhisper() throws {
        let whisper = FakeWhisperModelStore(["ggml-base": .downloading(0.4)])
        let model = make(whisper: whisper)
        let base = try row(model, "ggml-base")
        model.cancel(base)
        #expect(whisper.cancelled == ["ggml-base"])
        #expect(model.action(for: base) == .download)
    }

    @Test("T4-ROW-07 Parakeet gets percent and Cancel")
    func cancelParakeet() throws {
        let parakeet = FakeParakeetModelStore(.downloading(0.3))
        let model = make(parakeet: parakeet)
        let r = try row(model, "parakeet-v3")
        #expect(model.action(for: r) == .downloading(percent: 30))
        model.cancel(r)
        #expect(parakeet.cancelCount == 1)
        #expect(model.action(for: r) == .download)
    }

    @Test("T4-ROW-08 download failure shows Failed and Retry")
    func failure() throws {
        let whisper = FakeWhisperModelStore()
        let model = make(whisper: whisper)
        let small = try row(model, "ggml-small")
        whisper.fail("ggml-small", "HTTP 503")
        #expect(model.action(for: small) == .failed(message: "HTTP 503"))
        model.download(small)
        #expect(model.action(for: small) == .downloading(percent: 0))
    }

    @Test("T4-ROW-09 Apple Speech is built in; Not on this Mac when it cannot run")
    func apple() throws {
        let available = make()
        #expect(available.action(for: try row(available, "apple-speech")) == .builtIn)
        #expect(!ModelActionState.builtIn.showsTrash)
        let missing = make(apple: false)
        #expect(missing.action(for: try row(missing, "apple-speech")) == .notOnThisMac)
    }

    @Test("Parakeet row is hidden on Intel")
    func intel() {
        let model = make(parakeet: FakeParakeetModelStore(.notDownloaded, isSupportedHardware: false))
        #expect(!model.rows.contains { $0.id == "parakeet-v3" })
        #expect(model.rows.count == 13)
    }

    // MARK: Filter

    @Test("T4-FIL-01 mode filter")
    func modeFilter() {
        let model = make()
        model.modeFilter = .liveText
        #expect(!model.rows.contains { $0.id == "parakeet-v3" })
        #expect(model.rows.count == 13)
        model.modeFilter = .translateItself
        #expect(Set(model.rows.map(\.id)) == Set(multilingualNotTurbo))
    }

    @Test("T4-FIL-02 language filter")
    func languageFilter() {
        let model = make()
        model.languageFilter = "uk"
        let multilingual = Set(WhisperModelManager.availableModels.filter { !$0.isEnglishOnly }.map(\.name))
        #expect(Set(model.rows.map(\.id)) == multilingual.union(["parakeet-v3", "apple-speech"]))
        model.languageFilter = "en"
        #expect(Set(model.rows.map(\.id)) == multilingual.union(englishOnly).union(["parakeet-v3", "apple-speech"]))
        model.languageFilter = "ja"
        #expect(model.rows.contains { $0.id == "apple-speech" })
        #expect(!model.rows.contains { $0.id == "parakeet-v3" })
    }

    @Test("Translate itself + Maltese keeps the six models: Whisper lists Maltese (plan Q10, 100 languages)")
    func maltese() {
        let model = make()
        model.modeFilter = .translateItself
        model.languageFilter = "mt"
        #expect(Set(model.rows.map(\.id)) == Set(multilingualNotTurbo))
    }

    @Test("No match gives no rows (the view shows the empty row)")
    func empty() {
        let model = make()
        model.modeFilter = .translateItself
        model.languageFilter = "xx"
        #expect(model.rows.isEmpty)
    }

    @Test("Language options: Your languages first, then the union of local languages")
    func languageOptions() {
        let options = make().languageOptions
        #expect(Array(options.prefix(2)) == ["uk", "en"])
        #expect(options.count == 100)
        #expect(options.contains("mt"))
    }

    // MARK: Sort

    @Test("T4-SORT-01 sort by speed")
    func sortSpeed() {
        let ids = make().rows.map(\.id)
        #expect(Array(ids.prefix(9)) == [
            "parakeet-v3", turbo, "apple-speech", "ggml-tiny", "ggml-tiny.en", "ggml-base", "ggml-base.en",
            "ggml-large-v3-turbo-q5_0", "ggml-small"
        ])
    }

    @Test("T4-SORT-02 sort by accuracy")
    func sortAccuracy() {
        let model = make()
        model.sort = .accuracy
        #expect(Array(model.rows.map(\.id).prefix(6)) == [
            turbo, "parakeet-v3", "apple-speech", "ggml-large-v3", "ggml-large-v2", "ggml-large-v3-turbo-q5_0"
        ])
    }

    @Test("Rows do not move when a cell changes state")
    func stableOrder() throws {
        let whisper = FakeWhisperModelStore()
        let model = make(whisper: whisper)
        let before = model.rows.map(\.id)
        whisper.complete("ggml-small")
        model.use(try row(model, "ggml-small"))
        #expect(model.rows.map(\.id) == before)
    }

    // MARK: Cells

    @Test("T4-CELL-01 row cells")
    func cells() throws {
        let model = make()
        let parakeet = try row(model, "parakeet-v3")
        #expect(parakeet.live == ModelCellMark(kind: .no, subline: "After Stop"))
        #expect(parakeet.translation.map(\.kind) == [.byDiduny])
        #expect(parakeet.speedText == "Fastest")
        #expect(parakeet.sizeText == "480 MB")
        #expect(parakeet.isRecommended)
        if case let .list(title, list) = parakeet.languages {
            #expect(title == "25")
            #expect(list.languages.count == 25)
        } else {
            Issue.record("Parakeet must list its languages")
        }

        let apple = try row(model, "apple-speech")
        #expect(apple.live.kind == .yes)
        #expect(apple.languages == .system)
        #expect(apple.accuracyText == "about 8.5")
        #expect(apple.sizeText == "Built in")

        for name in multilingualNotTurbo {
            let r = try row(model, name)
            #expect(r.translation == [ModelCellMark(kind: .no, subline: "Itself: English only"),
                                      ModelCellMark(kind: .byDiduny, subline: "Any language")])
            if case let .list(title, _) = r.languages { #expect(title == "100") } else { Issue.record("\(name) list") }
        }
        for name in englishOnly + [turbo, "ggml-large-v3-turbo-q5_0"] {
            #expect(try row(model, name).translation.map(\.kind) == [.byDiduny])
        }
        for name in englishOnly { #expect(try row(model, name).languages == .englishOnly) }

        let large = try row(model, turbo)
        #expect(large.live.kind == .yes)
        #expect(large.speedText == "7.5")
        #expect(large.accuracyText == "9.7")
        #expect(large.sizeText == "1.5 GB")
        #expect(model.rows.filter(\.isRecommended).map(\.id) == ["parakeet-v3", turbo])
    }

    @Test("Size text matches the Size column for every model, independent of the system locale")
    func sizeFormat() {
        #expect(LocalModelSize.text(bytes: ParakeetProvider.downloadBytes) == "480 MB")
        for model in WhisperModelManager.availableModels {
            #expect(LocalModelSize.text(bytes: model.sizeBytes) == model.sizeDescription)
        }
    }
}
