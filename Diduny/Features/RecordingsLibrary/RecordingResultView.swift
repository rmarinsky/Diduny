import AppKit
import SwiftUI

/// The transcript versions of a recording, split for the result block. Pure, so it is tested.
struct RecordingVersions: Equatable {
    /// Original runs, newest first. The first is current.
    let originals: [TranscriptVersion]
    /// The newest translation per target language, in the order first made.
    let translations: [TranscriptVersion]

    init(_ recording: Recording) {
        let all = recording.resolvedTranscriptHistory.sorted { $0.createdAt > $1.createdAt }
        originals = all.filter { $0.kind != .translation }
        var seen = Set<String>()
        translations = all.filter { $0.kind == .translation }
            .filter { seen.insert($0.targetLanguageCode ?? "").inserted }
            .sorted { $0.createdAt < $1.createdAt }
    }

    var current: TranscriptVersion? { originals.first }
    var previousCount: Int { max(0, originals.count - 1) }
}

/// Who translates the text. Roman may name the translation service later: change only this string.
enum TranslationDestinationText {
    static var line: String { String(localized: "Text goes to Diduny.") }
}

/// Result block: actions, translation tabs, the current transcript and "Previous versions (N)".
struct RecordingResultView: View {
    let recording: Recording
    let onTranscribeAgain: () -> Void
    let onError: (String) -> Void

    @State private var tab: String = Self.originalTab
    @State private var viewedVersionID: UUID?
    @State private var showsPrevious = false
    @State private var translatingTo: String?

    private static let originalTab = "original"

    var body: some View {
        let versions = RecordingVersions(recording)
        let current = versions.current
        let translation = versions.translations.first { $0.targetLanguageCode == tab }
        let shown = translation ?? versions.originals.first { $0.id == viewedVersionID } ?? current
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            HStack(spacing: 6) {
                Button("Transcribe again", action: onTranscribeAgain)
                    .accessibilityIdentifier("recordings.result.again")
                translateMenu(versions)
                Button("Copy") {
                    if let shown { ClipboardService.shared.copy(text: shown.displayText, behavior: recording.type.clipboardCopyBehavior) }
                }
                .accessibilityIdentifier("recordings.result.copy")
                if translatingTo != nil { ProgressView().controlSize(.small) }
            }
            .controlSize(.small)

            if !versions.translations.isEmpty {
                ModeSegments(
                    items: [.init(id: Self.originalTab, title: "Original", accessibilityID: "recordings.result.tab.original")]
                        + versions.translations.map { version in
                            let code = version.targetLanguageCode ?? ""
                            return .init(id: code, title: LocalizedStringKey(Self.languageName(code)),
                                         accessibilityID: "recordings.result.tab.\(code)")
                        },
                    selection: $tab,
                    accessibilityLabel: "Transcript language"
                )
                .fixedSize()
            }

            if let shown {
                HStack(alignment: .firstTextBaseline, spacing: DS.Space.sm) {
                    Text(caption(shown, current: current))
                        .font(DS.Font.caption).foregroundStyle(DS.Palette.secondary)
                    if translation == nil, versions.previousCount > 0 {
                        Button(showsPrevious ? String(localized: "Hide previous versions")
                            : String(localized: "Previous versions (\(versions.previousCount))")) {
                            showsPrevious.toggle()
                        }
                        .buttonStyle(.link)
                        .font(DS.Font.caption)
                        .accessibilityIdentifier("recordings.result.previous")
                    }
                }
                if showsPrevious, translation == nil {
                    previousList(versions, shown: shown)
                }
                if translation == nil, shown.id != current?.id {
                    HStack {
                        Text("You are reading an earlier version. Copy takes this version.").font(DS.Font.callout)
                        Spacer()
                        Button("Back to current") { viewedVersionID = nil }.buttonStyle(.link)
                    }
                    .padding(.horizontal, 10).padding(.vertical, DS.Space.sm)
                    .background(DS.Palette.tint, in: RoundedRectangle(cornerRadius: DS.Radius.box))
                }
                if shown.sourceTrimRange != recording.trimRange {
                    Text("This transcript was created for a different audio range. Its timestamps refer to that version.")
                        .font(DS.Font.caption).foregroundStyle(DS.Palette.secondary)
                }
                Text(shown.displayText)
                    .font(DS.Font.body)
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("recordings.result.text")
            }
        }
    }

    private func previousList(_ versions: RecordingVersions, shown: TranscriptVersion) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(versions.originals.enumerated()), id: \.element.id) { index, version in
                Button {
                    viewedVersionID = index == 0 ? nil : version.id
                } label: {
                    HStack {
                        Text(Self.versionName(version) + (index == 0 ? String(localized: " (current)") : ""))
                            .fontWeight(version.id == shown.id ? .semibold : .regular)
                        Spacer()
                        Text(version.createdAt.formatted(date: .abbreviated, time: .shortened))
                            .font(DS.Font.caption).foregroundStyle(DS.Palette.secondary)
                    }
                    .padding(.horizontal, DS.Space.sm).padding(.vertical, 5)
                    .background(version.id == shown.id ? DS.Palette.chip : Color.clear, in: RoundedRectangle(cornerRadius: 5))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .font(DS.Font.callout)
        .padding(DS.Space.xs)
        .background(DS.Palette.box, in: RoundedRectangle(cornerRadius: DS.Radius.box))
    }

    private func translateMenu(_ versions: RecordingVersions) -> some View {
        Menu {
            Section(TranslationDestinationText.line) {
                ForEach(Self.favoriteLanguages) { languageButton($0, versions) }
            }
            Menu("All languages") {
                ForEach(Self.otherLanguages) { languageButton($0, versions) }
            }
        } label: {
            Text("Translate")
        }
        .fixedSize()
        .disabled(versions.current == nil || translatingTo != nil)
        .help(TranslationDestinationText.line)
        .accessibilityIdentifier("recordings.result.translate")
    }

    private func languageButton(_ language: SupportedLanguage, _ versions: RecordingVersions) -> some View {
        Button(language.name + (versions.translations.contains { $0.targetLanguageCode == language.code }
            ? String(localized: " (done, redo)") : "")) {
            translate(versions.current, to: language.code)
        }
    }

    /// Translates the existing transcript text; no audio is uploaded again.
    private func translate(_ version: TranscriptVersion?, to code: String) {
        guard let version else { return }
        translatingTo = code
        let id = recording.id
        Task { @MainActor in
            let step = await ByokTranslationStep.translate(version.displayText, targetLanguage: code,
                                                           translator: DidunyTextTranslationService())
            translatingTo = nil
            guard step.translated else {
                onError(String(localized: "The transcript could not be translated. Very long transcripts can not be translated yet. The transcript was not changed."))
                return
            }
            RecordingsLibraryStorage.shared.completeTranscription(
                id: id, status: .translated, text: step.text, segments: nil,
                translationTargetLanguageCode: code, kind: .translation,
                sourceLanguageCode: version.sourceLanguageCode
            )
            tab = code
        }
    }

    private func caption(_ version: TranscriptVersion, current: TranscriptVersion?) -> String {
        let when = version.createdAt.formatted(date: .abbreviated, time: .shortened)
        if version.kind == .translation, let current {
            return String(localized: "Translated from: \(Self.versionName(current)). \(when)")
        }
        return "\(Self.versionName(version)). \(when)"
    }

    static func versionName(_ version: TranscriptVersion) -> String {
        switch version.kind {
        case .cloud: String(localized: "Cloud transcript")
        case .local: version.modelIdentifier.map { String(localized: "On this Mac, \($0)") } ?? String(localized: "On this Mac")
        case .translation: languageName(version.targetLanguageCode ?? "")
        }
    }

    static func languageName(_ code: String) -> String {
        SupportedLanguage.language(for: code)?.name ?? code.uppercased()
    }

    private static var favoriteLanguages: [SupportedLanguage] {
        SettingsStorage.shared.favoriteLanguages.compactMap { SupportedLanguage.language(for: $0) }
    }

    private static var otherLanguages: [SupportedLanguage] {
        let favorites = Set(SettingsStorage.shared.favoriteLanguages)
        return SupportedLanguage.allLanguages.filter { !favorites.contains($0.code) }
    }
}
