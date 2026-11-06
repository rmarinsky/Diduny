@testable import Diduny
import Testing

/// Captions and menu sublines derived from the capability record (prototype v9 `modeSub`, `capLine`,
/// `recSub`, `tSub`, `withNote`, `blurb`). Copy is compared exactly.
struct EngineCaptionsTests {
    static func caps(_ id: EngineID) throws -> EngineCapabilities {
        try EngineCapabilitiesTests.capabilities(id)
    }

    /// A column of the Modes matrix (05 2.1.1): a job, plus the segment for Meeting.
    enum Column: String, Sendable, CaseIterable {
        case dictation, translation, meetingThisMac, meetingCloud, meetingRecordOnly, translateMeeting, files

        var job: STTJob {
            switch self {
            case .dictation: .dictation
            case .translation: .dictationTranslation
            case .meetingThisMac, .meetingCloud, .meetingRecordOnly: .meeting
            case .translateMeeting: .meetingTranslation
            case .files: .file
            }
        }

        var segment: MeetingSegment? {
            switch self {
            case .meetingThisMac: .thisMac
            case .meetingCloud: .cloud
            case .meetingRecordOnly: .recordOnly
            default: nil
            }
        }
    }

    struct Cell: CustomTestStringConvertible, Sendable {
        let engine: EngineID
        let column: Column
        let caption: String
        var testDescription: String { "\(engine.rawValue) x \(column.rawValue)" }
    }

    /// T5-MD-02: every offered cell of the 05 2.1.1 matrix with the v9 changes (Record only ElevenLabs
    /// gets speaker labels, design-spec 12.2; Translate meeting uses `tSub`, design-spec 12.3).
    /// "Not offered" cells are absent from menus through `ModeEngineRules.offeredEngines` (ADR-0012 D3, WP-13).
    static let matrix: [Cell] = [
        Cell(engine: .didunyCloud, column: .dictation, caption: "Text as you speak"),
        Cell(engine: .didunyCloud, column: .translation, caption: "Live translation"),
        Cell(engine: .didunyCloud, column: .meetingCloud, caption: "Live text · speaker labels"),
        Cell(engine: .didunyCloud, column: .meetingRecordOnly, caption: "After Stop, in the cloud, speaker labels"),
        Cell(engine: .didunyCloud, column: .translateMeeting, caption: "Live, both directions, speaker labels"),
        Cell(engine: .elevenLabs, column: .dictation, caption: "Text as you speak"),
        Cell(engine: .elevenLabs, column: .translation, caption: "By Diduny"),
        Cell(engine: .elevenLabs, column: .meetingCloud, caption: "Live text · no speaker labels"),
        Cell(engine: .elevenLabs, column: .meetingRecordOnly, caption: "After Stop, in the cloud, speaker labels"),
        Cell(engine: .elevenLabs, column: .translateMeeting, caption: "After Stop, by Diduny, into one language"),
        Cell(engine: .whisper, column: .dictation, caption: "Text as you speak (preview)"),
        Cell(engine: .whisper, column: .translation, caption: "By Diduny"),
        Cell(engine: .whisper, column: .meetingThisMac, caption: "Live text (preview) · no speaker labels"),
        Cell(engine: .whisper, column: .meetingRecordOnly, caption: "After Stop, on this Mac"),
        Cell(engine: .whisper, column: .translateMeeting, caption: "After Stop, by Diduny, into one language"),
        Cell(engine: .whisper, column: .files, caption: "On this Mac"),
        Cell(engine: .parakeet, column: .dictation, caption: "Text after Stop"),
        Cell(engine: .parakeet, column: .translation, caption: "By Diduny, after Stop"),
        Cell(engine: .parakeet, column: .meetingRecordOnly, caption: "After Stop, on this Mac"),
        Cell(engine: .parakeet, column: .translateMeeting, caption: "After Stop, by Diduny, into one language"),
        Cell(engine: .parakeet, column: .files, caption: "On this Mac"),
        Cell(engine: .appleSpeech, column: .dictation, caption: "Text as you speak"),
        Cell(engine: .appleSpeech, column: .translation, caption: "By Diduny"),
        Cell(engine: .appleSpeech, column: .meetingThisMac, caption: "Live text · no speaker labels"),
        Cell(engine: .appleSpeech, column: .meetingRecordOnly, caption: "After Stop, on this Mac"),
        Cell(engine: .appleSpeech, column: .translateMeeting, caption: "After Stop, by Diduny, into one language"),
        Cell(engine: .appleSpeech, column: .files, caption: "On this Mac")
    ]

    @Test("Mode by engine caption matrix", arguments: matrix)
    func modeCaption(_ cell: Cell) throws {
        let caption = EngineCaptions.caption(job: cell.column.job, segment: cell.column.segment, caps: try Self.caps(cell.engine))
        #expect(caption == cell.caption)
    }

    static let notes: [(EngineID, String?)] = [
        (.didunyCloud, nil), (.elevenLabs, nil), (.whisper, "Large v3 Turbo, recommended"),
        (.parakeet, "recommended"), (.appleSpeech, nil)
    ]

    @Test("Engine note", arguments: notes)
    func note(_ engine: EngineID, _ note: String?) throws {
        #expect(EngineCaptions.note(try Self.caps(engine)) == note)
    }

    @Test("Notes only in menus: the subline adds the note, the caption has none", arguments: matrix)
    func menuSublineAddsNote(_ cell: Cell) throws {
        let caps = try Self.caps(cell.engine)
        let subline = EngineCaptions.menuSubline(job: cell.column.job, segment: cell.column.segment, caps: caps)
        let expected = EngineCaptions.note(caps).map { "\(cell.caption) · \($0)" } ?? cell.caption
        #expect(subline == expected)
        #expect(!cell.caption.contains("recommended"))
    }

    @Test("Parakeet not downloaded replaces the whole subline", arguments: Column.allCases)
    func notDownloadedSubline(_ column: Column) throws {
        let subline = EngineCaptions.menuSubline(
            job: column.job, segment: column.segment, caps: try Self.caps(.parakeet),
            readiness: .notDownloaded(bytes: 480_000_000), locale: Self.enUS
        )
        #expect(subline == "Not downloaded, 480 MB")
    }

    /// Fixed locale for byte counts, so "480 MB" does not follow the test machine's region.
    static let enUS = Locale(identifier: "en_US")

    @Test("Menu sublines read readiness from an EngineReadinessSource")
    @MainActor
    func sublinesFromReadinessSource() throws {
        let source = FakeEngineReadinessSource([.parakeet: .notDownloaded(bytes: ParakeetProvider.downloadBytes)])
        for engine in EngineID.allCases {
            let caps = try Self.caps(engine)
            let subline = EngineCaptions.menuSubline(
                job: .file, caps: caps, readiness: source.readiness(of: engine), locale: Self.enUS
            )
            let expected = engine == .parakeet ? "Not downloaded, 480 MB" : EngineCaptions.menuSubline(job: .file, caps: caps)
            #expect(subline == expected, "\(engine.rawValue)")
        }
        #expect(source.requested == EngineID.allCases)
    }

    @Test("Command panel blurb replaced while Parakeet is not downloaded")
    func notDownloadedBlurb() throws {
        let caps = try Self.caps(.parakeet)
        #expect(EngineCaptions.withNote(
            EngineCaptions.blurb(caps), caps: caps, readiness: .notDownloaded(bytes: 480_000_000), locale: Self.enUS
        ) == "Not downloaded, 480 MB")
        #expect(EngineCaptions.withNote(EngineCaptions.blurb(caps), caps: caps) == "After Stop, 25 languages · recommended")
    }

    struct PanelCell: CustomTestStringConvertible, Sendable {
        let segment: MeetingSegment
        let engine: EngineID
        let text: String
        var testDescription: String { "\(segment.rawValue) + \(engine.rawValue)" }
    }

    /// T1-MT-02 (v9: ElevenLabs Record only has speaker labels).
    static let meetingCaptions: [PanelCell] = [
        PanelCell(segment: .cloud, engine: .didunyCloud, text: "Live text · speaker labels"),
        PanelCell(segment: .thisMac, engine: .whisper, text: "Live text (preview) · no speaker labels"),
        PanelCell(segment: .thisMac, engine: .appleSpeech, text: "Live text · no speaker labels"),
        PanelCell(segment: .cloud, engine: .elevenLabs, text: "Live text · no speaker labels"),
        PanelCell(segment: .recordOnly, engine: .whisper, text: "No live text · after Stop, on this Mac"),
        PanelCell(segment: .recordOnly, engine: .parakeet, text: "No live text · after Stop, on this Mac"),
        PanelCell(segment: .recordOnly, engine: .appleSpeech, text: "No live text · after Stop, on this Mac"),
        PanelCell(segment: .recordOnly, engine: .didunyCloud, text: "No live text · after Stop, in the cloud, speaker labels"),
        PanelCell(segment: .recordOnly, engine: .elevenLabs, text: "No live text · after Stop, in the cloud, speaker labels")
    ]

    @Test("Meeting panel caption follows engine and segment", arguments: meetingCaptions)
    func meetingPanelCaption(_ cell: PanelCell) throws {
        #expect(EngineCaptions.meetingPanelCaption(segment: cell.segment, caps: try Self.caps(cell.engine)) == cell.text)
    }

    /// T1-MT-03, key present, Parakeet downloaded.
    static let meetingMenuSublines: [PanelCell] = [
        PanelCell(segment: .thisMac, engine: .whisper, text: "Live text (preview) · no speaker labels · Large v3 Turbo, recommended"),
        PanelCell(segment: .thisMac, engine: .appleSpeech, text: "Live text · no speaker labels"),
        PanelCell(segment: .cloud, engine: .didunyCloud, text: "Live text · speaker labels"),
        PanelCell(segment: .cloud, engine: .elevenLabs, text: "Live text · no speaker labels · your key"),
        PanelCell(segment: .recordOnly, engine: .whisper, text: "After Stop, on this Mac · Large v3 Turbo, recommended"),
        PanelCell(segment: .recordOnly, engine: .parakeet, text: "After Stop, on this Mac · recommended"),
        PanelCell(segment: .recordOnly, engine: .appleSpeech, text: "After Stop, on this Mac"),
        PanelCell(segment: .recordOnly, engine: .didunyCloud, text: "After Stop, in the cloud, speaker labels"),
        PanelCell(segment: .recordOnly, engine: .elevenLabs, text: "After Stop, in the cloud, speaker labels")
    ]

    @Test("Meeting panel menu sublines carry the engine note", arguments: meetingMenuSublines)
    func meetingPanelMenuSubline(_ cell: PanelCell) throws {
        #expect(EngineCaptions.meetingPanelMenuSubline(segment: cell.segment, caps: try Self.caps(cell.engine)) == cell.text)
    }

    struct DictationCell: CustomTestStringConvertible, Sendable {
        let engine: EngineID
        let translating: Bool
        let text: String
        var testDescription: String { "\(engine.rawValue), \(translating ? "a language" : "Original")" }
    }

    /// T1-DI-02: engine sublines for Output "Original" and for Output a language (01 4 item 4).
    static let dictationSublines: [DictationCell] = [
        DictationCell(engine: .didunyCloud, translating: false, text: "Text as you speak"),
        DictationCell(engine: .elevenLabs, translating: false, text: "Text as you speak"),
        DictationCell(engine: .whisper, translating: false, text: "Text as you speak (preview) · Large v3 Turbo, recommended"),
        DictationCell(engine: .parakeet, translating: false, text: "Text after Stop · recommended"),
        DictationCell(engine: .appleSpeech, translating: false, text: "Text as you speak"),
        DictationCell(engine: .didunyCloud, translating: true, text: "Live translation"),
        DictationCell(engine: .elevenLabs, translating: true, text: "By Diduny"),
        DictationCell(engine: .whisper, translating: true, text: "By Diduny · Large v3 Turbo, recommended"),
        DictationCell(engine: .parakeet, translating: true, text: "By Diduny, after Stop · recommended"),
        DictationCell(engine: .appleSpeech, translating: true, text: "By Diduny")
    ]

    @Test("Dictation engine sublines follow Output", arguments: dictationSublines)
    func dictationSubline(_ cell: DictationCell) throws {
        let job: STTJob = cell.translating ? .dictationTranslation : .dictation
        #expect(EngineCaptions.menuSubline(job: job, caps: try Self.caps(cell.engine)) == cell.text)
    }

    /// T1-DI-03: the six captions of 01 4 item 5, for every engine.
    static let dictationCaptions: [DictationCell] = [
        DictationCell(engine: .didunyCloud, translating: false, text: "Text as you speak"),
        DictationCell(engine: .elevenLabs, translating: false, text: "Text as you speak"),
        DictationCell(engine: .appleSpeech, translating: false, text: "Text as you speak"),
        DictationCell(engine: .whisper, translating: false, text: "Text as you speak (preview)"),
        DictationCell(engine: .parakeet, translating: false, text: "Text after Stop"),
        DictationCell(engine: .didunyCloud, translating: true, text: "Live translation"),
        DictationCell(engine: .elevenLabs, translating: true, text: "You see your words. The translation by Diduny is pasted after Stop"),
        DictationCell(engine: .whisper, translating: true, text: "You see your words. The translation by Diduny is pasted after Stop"),
        DictationCell(engine: .appleSpeech, translating: true, text: "You see your words. The translation by Diduny is pasted after Stop"),
        DictationCell(engine: .parakeet, translating: true, text: "Text and translation by Diduny after Stop")
    ]

    @Test("Dictation caption follows Output and engine kind", arguments: dictationCaptions)
    func dictationCaption(_ cell: DictationCell) throws {
        #expect(EngineCaptions.dictationPanelCaption(translating: cell.translating, caps: try Self.caps(cell.engine)) == cell.text)
    }

    /// T1-TM-02 with the v9 `tSub` copy (design-spec 12.3 supersedes 01 3).
    static let translateMeetingSublines: [(EngineID, String)] = [
        (.didunyCloud, "Live, both directions, speaker labels"),
        (.elevenLabs, "After Stop, by Diduny, into one language"),
        (.whisper, "After Stop, by Diduny, into one language · Large v3 Turbo, recommended"),
        (.parakeet, "After Stop, by Diduny, into one language · recommended"),
        (.appleSpeech, "After Stop, by Diduny, into one language")
    ]

    @Test("Translate meeting engine sublines", arguments: translateMeetingSublines)
    func translateMeetingSubline(_ engine: EngineID, _ text: String) throws {
        #expect(EngineCaptions.menuSubline(job: .meetingTranslation, caps: try Self.caps(engine)) == text)
    }

    static let startsIn: [(MeetingSegment, String, String)] = [
        (.thisMac, "This Mac", "Live text made on this Mac"),
        (.cloud, "Cloud", "Live text from the cloud"),
        (.recordOnly, "Record only", "No live text. Transcript after Stop")
    ]

    @Test("Starts in menu rows", arguments: startsIn)
    func startsInRow(_ segment: MeetingSegment, _ title: String, _ subline: String) {
        #expect(EngineCaptions.startsIn(segment).title == title)
        #expect(EngineCaptions.startsIn(segment).subline == subline)
    }

    @Test("Starts in menu lists the three segments in order")
    func startsInOrder() {
        #expect(MeetingSegment.allCases == [.thisMac, .cloud, .recordOnly])
        #expect(MeetingSegment.allCases.map(\.rawValue) == ["thisMac", "cloud", "recordOnly"])
    }

    /// Command panel engine menu sublines (prototype `ENG.blurb`).
    static let blurbs: [(EngineID, String)] = [
        (.didunyCloud, "Live text, speaker labels, 60 languages"),
        (.elevenLabs, "Live text, 94 languages. Your key"),
        (.whisper, "Live preview, 100 languages"),
        (.parakeet, "After Stop, 25 languages"),
        (.appleSpeech, "Live text, macOS languages")
    ]

    @Test("Engine blurb", arguments: blurbs)
    func blurb(_ engine: EngineID, _ text: String) throws {
        #expect(EngineCaptions.blurb(try Self.caps(engine)) == text)
    }

    /// v9 Providers subline under the "Meeting speaker labels" mark (design-spec 12.2).
    static let afterStopLabels: [(EngineID, String?)] = [
        (.didunyCloud, nil), (.elevenLabs, "After Stop, up to 32"), (.whisper, nil), (.parakeet, nil), (.appleSpeech, nil)
    ]

    @Test("Speaker labels after Stop subline", arguments: afterStopLabels)
    func afterStopSpeakerLabels(_ engine: EngineID, _ text: String?) throws {
        #expect(EngineCaptions.afterStopSpeakerLabels(try Self.caps(engine)) == text)
    }
}
