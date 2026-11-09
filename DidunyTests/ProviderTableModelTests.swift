@testable import Diduny
import Testing

/// T3-CAP-02, T3-CAP-06 and the column sets of T3-TB-01 / T3-TB-02: every Providers cell comes from the
/// capability record (03 1.2 body table, v9 ElevenLabs speaker labels, Whisper per active model).
struct ProviderTableModelTests {
    private static func caps(whisper: String? = "ggml-large-v3") throws -> [EngineCapabilities] {
        let model = try whisper.map(EngineCapabilitiesTests.whisperModel)
        return try EngineID.allCases.map { try EngineCapabilitiesTests.capabilities($0, whisper: model) }
    }

    private static func model(hasKey: Bool = true, whisper: String? = "ggml-large-v3") throws -> ProviderTableModel {
        ProviderTableModel(capabilities: try caps(whisper: whisper), hasKey: hasKey)
    }

    /// Compact form: "Y", "Y|Preview", "N|Itself: only into English+D|Into any language".
    private static func code(_ parts: [ProviderMarkPart]) -> String {
        parts.map { part in
            let mark = switch part.kind { case .yes: "Y"; case .byDiduny: "D"; case .no: "N" }
            return part.subline.map { "\(mark)|\($0)" } ?? mark
        }.joined(separator: "+")
    }

    /// Columns: Diduny Cloud, ElevenLabs, Whisper, Parakeet V3, Apple Speech.
    static let expected: [ProviderRowID: [String]] = [
        .dictLive: ["Y", "Y", "Y|Preview", "N", "Y"],
        .dictAfterStop: ["Y", "Y", "Y", "Y", "Y"],
        .dictTranslation: ["Y|Live, any of 60 languages", "D", "N|Itself: only into English+D|Into any language", "D", "D"],
        .meetLive: ["Y", "Y", "Y|Preview", "N|After Stop only", "Y"],
        .meetLabels: ["Y|Live", "Y|After Stop, up to 32", "N", "N", "N"],
        .meetTranslation: ["Y|Live", "D|After Stop", "D|After Stop", "D|After Stop", "D|After Stop"],
        .translateSelected: ["Y", "D", "D", "D", "D"],
        .files: ["N|Files run on this Mac", "N|Files run on this Mac", "Y", "Y", "Y"]
    ]

    @Test("With a key: cloud columns first, ElevenLabs shown with Your key")
    func columnsWithKey() throws {
        let table = try Self.model(hasKey: true)
        #expect(table.columns.map(\.id) == [.didunyCloud, .elevenLabs, .whisper, .parakeet, .appleSpeech])
        #expect(table.cloudColumns.count == 2)
        #expect(table.localColumns.count == 3)
        #expect(table.columns.map(\.header) == [
            .subline("Built in"), .yourKey, .subline("Download"), .subline("Download"), .subline("In macOS")
        ])
        #expect(table.columns.map(\.name) == ["Diduny Cloud", "ElevenLabs", "Whisper", "Parakeet V3", "Apple Speech"])
    }

    @Test("Without a key there is no ElevenLabs column")
    func columnsWithoutKey() throws {
        let table = try Self.model(hasKey: false)
        #expect(table.columns.map(\.id) == [.didunyCloud, .whisper, .parakeet, .appleSpeech])
        #expect(table.cloudColumns.count == 1)
        #expect(!table.hasKeyColumn)
    }

    @Test("Every mark cell equals the 03 1.2 table", arguments: ProviderRowID.markRows)
    func markCells(_ row: ProviderRowID) throws {
        let table = try Self.model()
        #expect(table.columns.map { Self.code(ProviderTableModel.marks(row, $0.caps)) } == Self.expected[row])
    }

    @Test("Whisper Turbo does not translate itself: one By Diduny mark")
    func whisperTurboTranslation() throws {
        let table = try Self.model(whisper: "ggml-large-v3-turbo")
        let whisper = try #require(table.columns.first { $0.id == .whisper })
        #expect(Self.code(ProviderTableModel.marks(.dictTranslation, whisper.caps)) == "D")
        #expect(Self.code(ProviderTableModel.marks(.translateSelected, whisper.caps)) == "D")
    }

    @Test("Languages and Needs rows")
    func textRows() throws {
        let table = try Self.model()
        #expect(table.columns.map { ProviderTableModel.languagesLabel($0.caps) }
            == ["60 languages", "94 languages", "100 languages", "25 languages", "Set in macOS"])
        let locale = Locale(identifier: "en_US")
        #expect(table.columns.map { ProviderTableModel.needs($0.caps, locale: locale) }
            == ["Diduny account", "API key, ElevenLabs billing", "75 MB to 2.9 GB", "About 480 MB, Apple silicon", "Nothing"])
    }

    @Test("T3-CAP-06: one accessibility label per cell, By Diduny read once")
    func accessibilityLabel() throws {
        let table = try Self.model()
        let whisper = try #require(table.columns.first { $0.id == .whisper })
        let value = ProviderTableModel.accessibilityValue(ProviderTableModel.marks(.dictTranslation, whisper.caps))
        #expect(ProviderTableModel.accessibilityLabel(column: whisper.name, row: .dictTranslation, value: value)
            == "Whisper, Dictation translation: No, Itself: only into English. By Diduny, Into any language")
        let eleven = try #require(table.columns.first { $0.id == .elevenLabs })
        let labels = ProviderTableModel.accessibilityValue(ProviderTableModel.marks(.meetLabels, eleven.caps))
        #expect(ProviderTableModel.accessibilityLabel(column: eleven.name, row: .meetLabels, value: labels)
            == "ElevenLabs, Meeting speaker labels: Yes, After Stop, up to 32")
    }

    @Test("Table fills the 713.5 content column, with and without a key (label 135.7 without)")
    @MainActor func tableWidth() throws {
        for hasKey in [false, true] {
            let model = try Self.model(hasKey: hasKey)
            let ids = model.columns.map(\.id)
            let label = ProviderComparisonTable.labelWidth(columns: ids, withKey: model.hasKeyColumn)
            let total = ids.reduce(label) { $0 + ProviderComparisonTable.width(of: $1, withKey: model.hasKeyColumn) }
            #expect(abs(total - 713.5) < 0.01)
            #expect(label > 100)
            if !hasKey { #expect(abs(label - 135.7) < 0.01) }
        }
    }

    @Test("In a wider window every column scales and the table fills it")
    @MainActor func tableWidthInAWideWindow() throws {
        // 1600 window - 238 sidebar - 0.5 rule - 2 x 24 padding.
        let width: CGFloat = 1313.5
        for hasKey in [false, true] {
            let model = try Self.model(hasKey: hasKey)
            let ids = model.columns.map(\.id)
            let label = ProviderComparisonTable.labelWidth(columns: ids, withKey: model.hasKeyColumn, tableWidth: width)
            let total = ids.reduce(label) {
                $0 + ProviderComparisonTable.width(of: $1, withKey: model.hasKeyColumn, tableWidth: width)
            }
            #expect(abs(total - width) < 0.01)
            for id in ids {
                #expect(ProviderComparisonTable.width(of: id, withKey: model.hasKeyColumn, tableWidth: width)
                    > ProviderComparisonTable.width(of: id, withKey: model.hasKeyColumn))
            }
        }
    }
}
