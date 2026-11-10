import SwiftUI

/// "Make a transcript": On this Mac with a model menu, In the cloud with a provider menu, Speaker labels, the
/// download that a choice needs, and one button. Times are shown only where they were measured.
struct TranscribeChooserView: View {
    let recording: Recording
    let heading: String
    var isAgain = false
    var onCancel: (() -> Void)?
    let onRun: (TranscribeChoice.Run) -> Void

    @State private var choice: TranscribeChoice
    @State private var whisper = WhisperModelManager.shared
    @State private var parakeet = ParakeetModelController.shared
    @State private var speakerModel = SpeakerModelManager.shared

    init(recording: Recording, heading: String, isAgain: Bool = false, onCancel: (() -> Void)? = nil,
         onRun: @escaping (TranscribeChoice.Run) -> Void)
    {
        self.recording = recording
        self.heading = heading
        self.isAgain = isAgain
        self.onCancel = onCancel
        self.onRun = onRun
        _choice = State(initialValue: .defaults(offersLabels: Self.offersLabels(recording), facts: Self.readFacts()))
    }

    /// Voice notes have no labels switch; meetings and files do.
    static func offersLabels(_ recording: Recording) -> Bool { !recording.isVoiceNote }

    @MainActor static func readFacts() -> TranscribeFacts {
        var downloaded = Set<TranscribeChoice.MacModel>()
        if ParakeetModelStore.isDownloaded { downloaded.insert(.parakeet) }
        for model in [TranscribeChoice.MacModel.whisperTurbo, .whisperLarge] {
            if let name = model.whisperModelName, let whisper = WhisperModelManager.availableModels.first(where: { $0.name == name }),
               WhisperModelManager.shared.isModelDownloaded(whisper) { downloaded.insert(model) }
        }
        return TranscribeFacts(
            appleSilicon: ParakeetModelStore.isSupportedHardware,
            speakerModelSupported: LocalSpeakerDiarizer.isSupported,
            speakerModelReady: LocalSpeakerDiarizer.modelsDownloaded,
            downloaded: downloaded,
            appleSpeechReady: AppleBenchmarkEngine().availability() == .ready,
            elevenLabsKey: ProviderKeyStore.shared.key(for: STTProviderID.elevenLabs) != nil
        )
    }

    private var offersLabels: Bool { Self.offersLabels(recording) }
    private var offersCloud: Bool { !recording.requiresLocalTranscription }

    var body: some View {
        // Observed stores redraw the facts while a download runs.
        let facts = { _ = whisper.downloadProgress; _ = parakeet.state; _ = speakerModel.state; return Self.readFacts() }()
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            Text(heading).font(DS.Font.headline).padding(.top, DS.Space.sm)

            optionRow(place: .mac, title: "On this Mac", caption: macCaption(facts)) {
                PickerField(label: nil, value: Self.name(choice.mac), identifier: "recordings.transcribe.model",
                            menu: { macMenu(facts) }) { id in
                    if let model = TranscribeChoice.MacModel(rawValue: id) { choice.pick(model) }
                }
                .fixedSize()
            }
            if offersCloud {
                optionRow(place: .cloud, title: "In the cloud", caption: cloudCaption) {
                    PickerField(label: nil, value: Self.name(choice.cloud), identifier: "recordings.transcribe.provider",
                                menu: { cloudMenu(facts) }) { id in
                        if let service = TranscribeChoice.CloudService(rawValue: id) { choice.pick(service) }
                    }
                    .fixedSize()
                }
            } else {
                caption("Imported files and YouTube audio are transcribed on this Mac.")
            }

            if offersLabels { labelsRow(facts) }
            if let note = choice.note { caption(noteText(note)) }
            if choice.place == .mac { needBox(facts) }

            HStack(spacing: DS.Space.sm) {
                Button(goTitle) { onRun(choice.run(offersLabels: offersLabels)) }
                    .buttonStyle(.borderedProminent)
                    .tint(DS.Palette.accent)
                    .controlSize(.large)
                    .disabled(choice.blocker(facts) != nil || recording.status == .processing)
                    .accessibilityIdentifier("recordings.transcribe.go")
                if let onCancel {
                    Button("Cancel", action: onCancel).controlSize(.large)
                }
            }
            .padding(.top, DS.Space.xs)
            if isAgain { caption("Adds a new version. Earlier transcripts stay.") }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("recordings.transcribe")
    }

    // MARK: - Rows

    private func optionRow(place: TranscribeChoice.Place, title: LocalizedStringKey, caption text: String,
                           @ViewBuilder field: () -> some View) -> some View
    {
        HStack(alignment: .top, spacing: DS.Space.sm) {
            Button { choice.choose(place) } label: {
                HStack(alignment: .top, spacing: DS.Space.sm) {
                    Circle()
                        .strokeBorder(choice.place == place ? DS.Palette.accentFill : DS.Palette.secondary,
                                      lineWidth: choice.place == place ? 4 : 1.5)
                        .frame(width: 14, height: 14)
                        .padding(.top, 2)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(DS.Font.headline)
                        Text(text).font(DS.Font.caption).foregroundStyle(DS.Palette.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(choice.place == place ? .isSelected : [])
            field()
        }
        .padding(.vertical, 4)
    }

    private func labelsRow(_ facts: TranscribeFacts) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Speaker labels").font(DS.Font.headline)
                Text(labelsCaption(facts)).font(DS.Font.caption).foregroundStyle(DS.Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Toggle("Speaker labels", isOn: Binding(get: { choice.labels }, set: { choice.setLabels($0) }))
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
                .tint(DS.Palette.accent)
                .accessibilityIdentifier("recordings.transcribe.labels")
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func needBox(_ facts: TranscribeFacts) -> some View {
        switch choice.blocker(facts) {
        case .notOnThisMac:
            box {
                Text(choice.mac == .parakeet
                    ? String(localized: "Parakeet V3 needs Apple silicon. Choose Whisper, or transcribe in the cloud.")
                    : String(localized: "Apple Speech is not available on this Mac. Choose another model, or transcribe in the cloud."))
            }
        case let .download(model):
            box {
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(Self.name(model)) needs a download, \(Self.size(Self.bytes(model))).")
                    if let progress = progress(model) {
                        ProgressView(value: progress).progressViewStyle(.linear).tint(DS.Palette.accent)
                        HStack {
                            Text("\(Self.size(Int64(Double(Self.bytes(model)) * progress))) of \(Self.size(Self.bytes(model)))")
                                .monospacedDigit()
                            Spacer()
                            Button("Cancel") { cancelDownload(model) }.buttonStyle(.link)
                        }
                    } else {
                        Button("Download \(Self.size(Self.bytes(model)))") { download(model) }
                            .accessibilityIdentifier("recordings.transcribe.download")
                    }
                    if choice.labels, model.canLabelSpeakers {
                        Text("Or turn speaker labels off to use Parakeet.").foregroundStyle(DS.Palette.secondary)
                    }
                }
            }
        case nil:
            if offersLabels, choice.labels, choice.mac.canLabelSpeakers {
                if !facts.speakerModelSupported {
                    box {
                        Text("Speaker labels on this Mac are Me and Others only. Telling voices apart needs Apple silicon and macOS 15. For Speaker 1, Speaker 2, choose Diduny Cloud.")
                    }
                } else if !facts.speakerModelReady {
                    box {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("You can transcribe now with Me and Others only. The speaker model tells voices apart.")
                            if speakerModel.state == .downloading {
                                HStack { ProgressView().controlSize(.small); Text("Downloading the speaker model…") }
                            } else {
                                Button("Download \(LocalSpeakerDiarizer.modelDownloadMegabytes) MB") {
                                    speakerModel.downloadIfNeeded()
                                }
                                .accessibilityIdentifier("recordings.transcribe.downloadSpeakers")
                            }
                        }
                    }
                }
            }
        }
    }

    private func box(@ViewBuilder _ content: () -> some View) -> some View {
        content()
            .font(DS.Font.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, DS.Space.sm)
            .background(DS.Palette.box, in: RoundedRectangle(cornerRadius: DS.Radius.box))
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(DS.Font.caption).foregroundStyle(DS.Palette.secondary).fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Menus

    private func macMenu(_ facts: TranscribeFacts) -> PickerMenuModel {
        let rows = TranscribeChoice.MacModel.allCases.map { model in
            var state: String
            var enabled = true
            switch model {
            case .parakeet where !facts.appleSilicon:
                state = String(localized: "Needs Apple silicon")
                enabled = false
            case .apple:
                state = facts.appleSpeechReady ? String(localized: "Built into macOS") : String(localized: "Not available on this Mac")
                enabled = facts.appleSpeechReady
            default:
                state = facts.downloaded.contains(model) ? String(localized: "Downloaded")
                    : String(localized: "Not downloaded, \(Self.size(Self.bytes(model)))")
            }
            let ability = model.canLabelSpeakers ? String(localized: "Speaker labels.") : String(localized: "No speaker labels.")
            return PickerMenuRow(id: model.rawValue, title: Self.name(model), subline: "\(state). \(ability)", isEnabled: enabled)
        }
        return PickerMenuModel(groups: [PickerMenuGroup(id: "onThisMac", rows: rows)], selectedID: choice.mac.rawValue,
                               search: .never)
    }

    private func cloudMenu(_ facts: TranscribeFacts) -> PickerMenuModel {
        var rows = [PickerMenuRow(id: TranscribeChoice.CloudService.diduny.rawValue, title: Self.name(.diduny),
                                  subline: String(localized: "Your Diduny plan. Speaker labels."))]
        if facts.elevenLabsKey {
            rows.append(PickerMenuRow(id: TranscribeChoice.CloudService.elevenLabs.rawValue, title: Self.name(.elevenLabs),
                                      subline: String(localized: "Your own key, billed by ElevenLabs. Speaker labels, up to 32 people.")))
        }
        return PickerMenuModel(groups: [PickerMenuGroup(id: "cloud", rows: rows)], selectedID: choice.cloud.rawValue,
                               search: .never)
    }

    // MARK: - Text

    private var goTitle: String {
        switch choice.place {
        case .mac: String(localized: "Transcribe on this Mac")
        case .cloud: String(localized: "Transcribe with \(Self.name(choice.cloud))")
        }
    }

    /// Measured on an M1 Pro (README "Facts from code"): Parakeet about 88x real time, Whisper Turbo about 8.4x.
    /// Nothing else has been measured, so nothing else shows a number.
    private func macCaption(_ facts: TranscribeFacts) -> String {
        var text = String(localized: "Audio stays on your Mac.")
        let speed: Double? = switch choice.mac {
        case .parakeet: 88
        case .whisperTurbo: 8.4
        case .whisperLarge, .apple: nil
        }
        if let speed {
            let seconds = recording.effectiveDurationSeconds / speed
            text += " " + String(localized: "About \(Self.duration(seconds)) on an M1 Pro")
            text += choice.labels && offersLabels && choice.mac.canLabelSpeakers
                ? String(localized: ", then a step to tell voices apart.") : "."
        } else {
            text += " " + String(localized: "Time not measured yet.")
        }
        return text
    }

    private var cloudCaption: String {
        switch choice.cloud {
        case .diduny:
            let minutes = Int((recording.effectiveDurationSeconds / 60).rounded(.up))
            return String(localized: "Audio is uploaded to Diduny. Uses \(minutes) min of your plan.")
        case .elevenLabs:
            return String(localized: "Audio is uploaded to ElevenLabs with your key and billed there. Time not measured yet.")
        }
    }

    private func labelsCaption(_ facts: TranscribeFacts) -> String {
        if choice.place == .cloud {
            return choice.cloud == .diduny
                ? String(localized: "Who said what: Speaker 1, Speaker 2. Diduny Cloud does this.")
                : String(localized: "Who said what, up to 32 people. ElevenLabs does this.")
        }
        if !choice.mac.canLabelSpeakers {
            return String(localized: "\(Self.name(choice.mac)) can not tell voices apart. Turning this on switches to Whisper Large v3 Turbo.")
        }
        return choice.meAndOthersOnly(facts)
            ? String(localized: "Me and Others only.")
            : String(localized: "Who said what: Me, Speaker 2 (remote). Done on this Mac after the transcript.")
    }

    private func noteText(_ note: TranscribeChoice.Note) -> String {
        switch note {
        case .modelChangedForLabels: String(localized: "Model changed to Whisper Large v3 Turbo, which can tell voices apart.")
        case .labelsOffForModel: String(localized: "Speaker labels turned off: this model can not tell voices apart.")
        }
    }

    // MARK: - Downloads

    private func whisperModel(_ model: TranscribeChoice.MacModel) -> WhisperModelManager.WhisperModel? {
        model.whisperModelName.flatMap { name in WhisperModelManager.availableModels.first { $0.name == name } }
    }

    private func progress(_ model: TranscribeChoice.MacModel) -> Double? {
        if model == .parakeet, case let .downloading(value) = parakeet.state { return value }
        guard let name = model.whisperModelName, whisper.isDownloading[name] == true else { return nil }
        return whisper.downloadProgress[name] ?? 0
    }

    private func download(_ model: TranscribeChoice.MacModel) {
        if model == .parakeet { parakeet.download() } else if let whisperModel = whisperModel(model) {
            whisper.downloadModel(whisperModel)
        }
    }

    private func cancelDownload(_ model: TranscribeChoice.MacModel) {
        if model == .parakeet { parakeet.cancel() } else if let whisperModel = whisperModel(model) {
            whisper.cancelDownload(whisperModel)
        }
    }

    static func bytes(_ model: TranscribeChoice.MacModel) -> Int64 {
        switch model {
        case .parakeet: ParakeetProvider.downloadBytes
        case .apple: 0
        case .whisperTurbo, .whisperLarge:
            model.whisperModelName.flatMap { name in WhisperModelManager.availableModels.first { $0.name == name } }?.sizeBytes ?? 0
        }
    }

    static func name(_ model: TranscribeChoice.MacModel) -> String {
        switch model {
        case .parakeet: "Parakeet V3"
        case .whisperTurbo: "Whisper Large v3 Turbo"
        case .whisperLarge: "Whisper Large v3"
        case .apple: "Apple Speech"
        }
    }

    static func name(_ service: TranscribeChoice.CloudService) -> String {
        service == .diduny ? "Diduny Cloud" : "ElevenLabs"
    }

    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .decimal)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        seconds < 60
            ? String(localized: "\(max(1, Int(seconds.rounded()))) s")
            : String(localized: "\(Int((seconds / 60).rounded())) min")
    }
}
