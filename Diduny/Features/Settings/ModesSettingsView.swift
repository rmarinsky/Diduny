import KeyboardShortcuts
import SwiftUI

/// Settings > Modes (design-spec 7.11, 05 2.1): what runs each mode by default, and how you start it.
struct ModesSettingsView: View {
    @State private var model: ModesViewModel

    init(model: ModesViewModel? = nil) {
        _model = State(initialValue: model ?? Self.liveModel())
    }

    @MainActor
    private static func liveModel() -> ModesViewModel {
        let whisper = WhisperModelManager.availableModels.first { $0.name == SettingsStorage.shared.selectedWhisperModel }
        let model = ModesViewModel(
            source: LiveModesSettingsSource(),
            readiness: LiveEngineReadinessSource(),
            engines: ProviderRegistry.shared.modules.compactMap { EngineCapabilities.make($0, activeWhisperModel: whisper) },
            isSignedIn: { AuthService.hasStoredSession }
        )
        #if TEST_BUILD
            if let job = UITestOpenTarget.requestedModesJob { model.expand(job) }
        #endif
        return model
    }

    var body: some View {
        PageScaffold(title: "Modes", subtitle: "What runs each mode by default, and how you start it.") {
            VStack(alignment: .leading, spacing: 0) {
                if model.showsSignedOutNotice {
                    NoticeRow(text: "You are signed out. Recording and translation by Diduny need an account.", buttonTitle: "Sign in") {
                        MainWindowController.shared.showWindow(section: .account)
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("modes.signedOutNotice")
                    .padding(.bottom, 14)
                }
                uniformRow.padding(.bottom, DS.Space.lg)
                grid(widths: ModesGrid.flexibleWidths(total: contentWidth))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onGeometryChange(for: CGFloat.self, of: \.size.width) { contentWidth = $0 }
                footer.padding(.top, 12)
            }
        }
        .onAppear {
            model.reload()
            openRequestedExpander()
        }
        .onChange(of: MainWindowController.shared.requestedModesExpander) { _, _ in openRequestedExpander() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.reload() }
    }

    private func openRequestedExpander() {
        guard let job = MainWindowController.shared.requestedModesExpander else { return }
        MainWindowController.shared.requestedModesExpander = nil
        model.expand(job)
    }

    /// Content column at the default window size (design-spec 3.5); measured on layout.
    @State private var contentWidth: CGFloat = 713.5

    private var uniformRow: some View {
        HStack(spacing: 12) {
            Text("Use one engine for everything")
                .font(DS.Font.body)
                .foregroundStyle(DS.Palette.text)
            PickerField(label: nil, value: model.uniformEngineValue, identifier: "modes.allEngines") {
                model.uniformEngineMenu()
            } onPick: { model.pickUniformEngine($0) }
            .frame(width: 220)
        }
    }

    private func grid(widths: (engine: CGFloat, second: CGFloat)) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            header(widths: widths)
            ForEach(ModesViewModel.jobs, id: \.self) { job in
                VStack(alignment: .leading, spacing: 0) {
                    row(job, widths: widths)
                    if let bytes = model.notDownloadedBytes(for: job) {
                        WarningLine(
                            message: String(localized: "Parakeet V3 is not downloaded. Until it is, Whisper Large v3 Turbo makes the transcript."),
                            linkTitle: model.downloadLinkTitle(bytes: bytes),
                            action: { MainWindowController.shared.showWindow(section: .models) },
                            id: "modes.\(job.rawValue).parakeetMissing",
                            linkID: "modes.\(job.rawValue).downloadParakeet"
                        )
                        .padding(.leading, ModesGrid.detailIndent)
                        .padding(.bottom, 10)
                    }
                    if model.expandedJob == job {
                        ModeExpander(job: job, model: model)
                    }
                    Rectangle().fill(DS.Palette.line).frame(height: 1)
                }
            }
        }
    }

    private func header(widths: (engine: CGFloat, second: CGFloat)) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: ModesGrid.gap) {
                Text("Mode").frame(width: ModesGrid.modeColumn, alignment: .leading)
                Text("Engine").frame(width: widths.engine, alignment: .leading)
                Color.clear.frame(width: widths.second, height: 1)
                Text("Shortcut").frame(width: ModesGrid.shortcutColumn, alignment: .leading)
            }
            .font(DS.Font.captionStrong)
            .foregroundStyle(DS.Palette.secondary)
            Rectangle().fill(DS.Palette.line).frame(height: 1)
        }
    }

    @ViewBuilder private func row(_ job: STTJob, widths: (engine: CGFloat, second: CGFloat)) -> some View {
        switch job {
        case .dictation:
            ModeRow(job: job, title: String(localized: "Dictation"), symbol: "mic", widths: widths, model: model, shortcut: .toggleRecording) {
                EmptyView()
            }
        case .dictationTranslation:
            ModeRow(job: job, title: String(localized: "Translation"), symbol: "globe", widths: widths, model: model, shortcut: .toggleTranslation) {
                PickerField(label: "Into", value: model.intoValue, identifier: "modes.dictationTranslation.into") {
                    model.intoMenu()
                } onPick: { model.pickInto($0) }
            }
        case .meeting:
            ModeRow(job: job, title: String(localized: "Meeting"), symbol: "person.2", widths: widths, model: model, shortcut: .toggleMeetingRecording) {
                PickerField(label: "Starts in", value: model.startsInValue, identifier: "modes.meeting.startsIn") {
                    model.startsInMenu()
                } onPick: { model.pickStartsIn($0) }
            }
        case .meetingTranslation:
            ModeRow(job: job, title: String(localized: "Translate meeting"), symbol: "person.2", widths: widths, model: model, shortcut: .toggleMeetingTranslation) {
                PickerField(label: "Between", value: model.betweenValue, identifier: "modes.meetingTranslation.between") {
                    model.betweenMenu()
                } onPick: { rowID in
                    // "Other languages..." opens Settings > Languages; `.languages` arrives with WP-50.
                    if !model.pickBetween(rowID) { MainWindowController.shared.showWindow(section: .general) }
                }
            }
        case .file:
            ModeRow(job: job, title: String(localized: "Files and URLs"), symbol: "doc", widths: widths, model: model, shortcut: nil, fixedShortcut: "⇧⌘B") {
                EmptyView()
            }
        }
    }

    private var footer: some View {
        InlineLink(title: "Compare engines in Providers") {
            MainWindowController.shared.showWindow(section: .providers)
        }
        .font(DS.Font.callout)
        .accessibilityIdentifier("modes.footer.providers")
    }
}
