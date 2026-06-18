import AVFoundation
import SwiftUI

struct AudioDictationSettingsView: View {
    @Environment(AppState.self) var appState
    @Environment(AudioDeviceManager.self) var deviceManager
    @StateObject private var testRecorderService = AudioRecorderService()

    @State private var isTestPlaying = false
    @State private var testRecordingURL: URL?
    @State private var testAudioPlayer: AVAudioPlayer?
    @State private var testStatusMessage = ""

    @State private var transcriptionProvider: TranscriptionProvider = SettingsStorage.shared.transcriptionProvider
    @State private var translationProvider: TranscriptionProvider = SettingsStorage.shared.translationProvider
    @State private var manualLanguageCodes = Set(SettingsStorage.shared.manualSpeechLanguageHints)
    @State private var disabledDetectedLanguageCodes = Set(SettingsStorage.shared.disabledDetectedSpeechLanguageHints)
    @State private var translationPairs = SettingsStorage.shared.translationLanguagePairs
    @State private var defaultPairID = SettingsStorage.shared.defaultTranslationLanguagePairID
    @State private var isManagingSpeechLanguages = false
    @State private var isEditingPair = false
    @State private var pairBeingEdited: TranslationLanguagePair?

    private var detectedLanguages: [KeyboardLanguageDetector.DetectedLanguage] {
        KeyboardLanguageDetector.detectedLanguages()
    }

    private var sonioxLanguageHints: [String] {
        let enabledDetected = detectedLanguages.map(\.code).filter { !disabledDetectedLanguageCodes.contains($0) }
        return SettingsStorage.normalizedLanguageCodes(
            enabledDetected + Array(manualLanguageCodes),
            fallback: ["en", "uk"]
        )
    }

    var body: some View {
        Form {
            inputDeviceSection
            testRecordingSection
            providerSection
            speechLanguagesSection

            if translationProvider == .cloud {
                translationPairsSection(isDisabled: false)
            } else {
                localWhisperSection
                translationPairsSection(isDisabled: true)
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: refreshState)
        .onDisappear { cleanupTestRecording() }
        .sheet(isPresented: $isManagingSpeechLanguages) {
            SpeechLanguageManagementSheet(
                manualCodes: $manualLanguageCodes,
                disabledDetectedCodes: $disabledDetectedLanguageCodes,
                detectedLanguages: detectedLanguages,
                onSave: persistSpeechLanguages
            )
        }
        .sheet(isPresented: $isEditingPair) {
            TranslationPairEditorSheet(pair: pairBeingEdited) { pair in
                upsertPair(pair)
            }
        }
    }

    // MARK: - Sections

    private var inputDeviceSection: some View {
        Section("Microphone") {
            let effectiveUID = deviceManager.effectiveDeviceUID(preferred: appState.preferredDeviceUID)
            let isSystemDefault = effectiveUID == nil
            let preferredIsStale = appState.preferredDeviceUID != nil && effectiveUID == nil

            microphoneRow(
                title: "System Default",
                subtitle: systemDefaultSubtitle(preferredIsStale: preferredIsStale),
                isSelected: isSystemDefault
            ) {
                appState.preferredDeviceUID = nil
            }

            ForEach(deviceManager.availableDevices) { device in
                let isSelected = deviceManager.effectiveDeviceUID(preferred: appState.preferredDeviceUID) == device.uid
                microphoneRow(
                    title: device.name,
                    subtitle: deviceSubtitle(for: device),
                    isSelected: isSelected
                ) {
                    appState.preferredDeviceUID = device.uid
                }
            }
        }
    }

    private var testRecordingSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Button {
                        if isTestRecording { stopTestRecording() } else { startTestRecording() }
                    } label: {
                        Label(isTestRecording ? "Stop Recording" : "Test Microphone",
                              systemImage: isTestRecording ? "stop.circle.fill" : "mic.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(isTestRecording ? .red : .accentColor)
                    .disabled(isTestPlaying)

                    if testRecordingURL != nil, !isTestRecording {
                        Button {
                            if isTestPlaying { stopTestPlayback() } else { playTestRecording() }
                        } label: {
                            Label(isTestPlaying ? "Stop" : "Play", systemImage: isTestPlaying ? "stop.fill" : "play.fill")
                        }
                        .buttonStyle(.bordered)
                    }
                }

                if isTestRecording {
                    HStack {
                        Text("Level")
                            .foregroundStyle(.secondary)
                        GeometryReader { geometry in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Color.gray.opacity(0.22))
                                    .frame(height: 8)
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(levelColor)
                                    .frame(width: geometry.size.width * CGFloat(testRecorderService.audioLevel), height: 8)
                            }
                        }
                        .frame(height: 8)
                    }
                }

                if !testStatusMessage.isEmpty {
                    Text(testStatusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Test Recording")
        }
    }

    private var providerSection: some View {
        Section("Providers") {
            Picker("Transcription", selection: $transcriptionProvider) {
                ForEach(TranscriptionProvider.allCases) { provider in
                    Text(provider.displayName).tag(provider)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: transcriptionProvider) { _, value in
                SettingsStorage.shared.transcriptionProvider = value
            }

            Picker("Translation", selection: $translationProvider) {
                ForEach(TranscriptionProvider.allCases) { provider in
                    Text(provider.displayName).tag(provider)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: translationProvider) { _, value in
                SettingsStorage.shared.translationProvider = value
            }
        }
    }

    private var speechLanguagesSection: some View {
        Section("Speech Languages") {
            VStack(alignment: .leading, spacing: 10) {
                languageChipGrid(languages: detectedLanguages.map { language in
                    LanguageChipModel(
                        code: language.code,
                        title: displayName(for: language.code),
                        subtitle: language.sourceName,
                        isMuted: disabledDetectedLanguageCodes.contains(language.code),
                        source: "Mac layout"
                    )
                })

                let manualOnly = manualLanguageCodes
                    .filter { code in !detectedLanguages.contains(where: { $0.code == code }) }
                    .sorted()
                if !manualOnly.isEmpty {
                    Divider()
                    languageChipGrid(languages: manualOnly.map { code in
                        LanguageChipModel(
                            code: code,
                            title: displayName(for: code),
                            subtitle: "Manual",
                            isMuted: false,
                            source: "Manual"
                        )
                    })
                }

                HStack(spacing: 8) {
                    Label("Sent to Soniox: \(sonioxLanguageHints.joined(separator: ", "))", systemImage: "antenna.radiowaves.left.and.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Manage...") {
                        isManagingSpeechLanguages = true
                    }
                }
            }
        }
    }

    private func translationPairsSection(isDisabled: Bool) -> some View {
        Section("Translation Pairs") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(translationPairs) { pair in
                    TranslationPairRow(
                        pair: pair,
                        isDefault: pair.id == defaultPairID,
                        isLastUsed: pair.id == SettingsStorage.shared.lastUsedTranslationLanguagePairID,
                        isDisabled: isDisabled,
                        onMakeDefault: { makeDefault(pair) },
                        onEdit: { editPair(pair) },
                        onDelete: { removePair(pair) }
                    )
                }

                HStack {
                    Button {
                        addPair()
                    } label: {
                        Label("Add Pair", systemImage: "plus")
                    }
                    .disabled(isDisabled)

                    if isDisabled {
                        Spacer()
                        Text("Local Whisper translates to English only.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var localWhisperSection: some View {
        Section("Local Whisper Translation") {
            Label("Voice translation target: English", systemImage: "info.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
            whisperTranslationStatus
        }
    }

    // MARK: - Whisper Translation Status

    @ViewBuilder
    private var whisperTranslationStatus: some View {
        let selected = WhisperModelManager.shared.selectedModel()
        if let model = selected {
            if model.isEnglishOnly {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Model \"\(model.displayName)\" is English-only").fontWeight(.medium)
                        Text("Select a multilingual model in Models.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            } else {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Model \"\(model.displayName)\" supports translation").fontWeight(.medium)
                        Text("Speech in any language will be translated to English.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
            }
        } else {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("No model selected").fontWeight(.medium)
                    Text("Download and select a multilingual model in Models.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
        }
    }

    // MARK: - UI Helpers

    private func microphoneRow(
        title: String,
        subtitle: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 8) {
            RadioButton(isSelected: isSelected, action: action)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .foregroundStyle(isSelected ? .primary : .secondary)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
    }

    private func languageChipGrid(languages: [LanguageChipModel]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 116), spacing: 8)], alignment: .leading, spacing: 8) {
            ForEach(languages) { language in
                LanguageChip(model: language)
            }
        }
    }

    private func displayName(for code: String) -> String {
        SupportedLanguage.language(for: code)?.name ?? code.uppercased()
    }

    private func systemDefaultSubtitle(preferredIsStale: Bool) -> String {
        if preferredIsStale {
            return "Unavailable -> System Default"
        }
        return deviceManager.defaultDevice?.name ?? ""
    }

    private func refreshState() {
        transcriptionProvider = SettingsStorage.shared.transcriptionProvider
        translationProvider = SettingsStorage.shared.translationProvider
        manualLanguageCodes = Set(SettingsStorage.shared.manualSpeechLanguageHints)
        disabledDetectedLanguageCodes = Set(SettingsStorage.shared.disabledDetectedSpeechLanguageHints)
        translationPairs = SettingsStorage.shared.translationLanguagePairs
        defaultPairID = SettingsStorage.shared.defaultTranslationLanguagePairID
    }

    private func persistSpeechLanguages() {
        SettingsStorage.shared.manualSpeechLanguageHints = SupportedLanguage.cloudLanguages
            .map(\.code)
            .filter { manualLanguageCodes.contains($0) }
        SettingsStorage.shared.disabledDetectedSpeechLanguageHints = Array(disabledDetectedLanguageCodes).sorted()
        refreshState()
    }

    private func upsertPair(_ pair: TranslationLanguagePair) {
        if let index = translationPairs.firstIndex(where: { $0.id == pair.id }) {
            translationPairs[index] = pair
        } else {
            translationPairs.append(pair)
        }
        persistPairs()
    }

    private func makeDefault(_ pair: TranslationLanguagePair) {
        defaultPairID = pair.id
        persistPairs()
    }

    private func addPair() {
        pairBeingEdited = nil
        isEditingPair = true
    }

    private func editPair(_ pair: TranslationLanguagePair) {
        pairBeingEdited = pair
        isEditingPair = true
    }

    private func removePair(_ pair: TranslationLanguagePair) {
        guard translationPairs.count > 1 else { return }
        translationPairs.removeAll { $0.id == pair.id }
        if defaultPairID == pair.id {
            defaultPairID = translationPairs[0].id
        }
        persistPairs()
    }

    private func persistPairs() {
        SettingsStorage.shared.translationLanguagePairs = translationPairs
        SettingsStorage.shared.defaultTranslationLanguagePairID = defaultPairID
        translationPairs = SettingsStorage.shared.translationLanguagePairs
        defaultPairID = SettingsStorage.shared.defaultTranslationLanguagePairID
    }

    private var levelColor: Color {
        testRecorderService.audioLevel > 0.8 ? .red : testRecorderService.audioLevel > 0.5 ? .yellow : .green
    }

    private var isTestRecording: Bool { testRecorderService.isRecording }

    private func deviceSubtitle(for device: AudioDevice) -> String {
        var parts: [String] = []
        if device.isDefault { parts.append("Default") }
        if device.transportType != .unknown { parts.append(device.transportType.displayName) }
        return parts.joined(separator: " · ")
    }

    private func startTestRecording() {
        let (device, _) = deviceManager.resolveDevice(preferredUID: appState.preferredDeviceUID)
        testStatusMessage = "Starting test recording..."
        Task { @MainActor in
            do {
                try await testRecorderService.startRecording(device: device)
                testStatusMessage = "Recording... speak into your microphone"
            } catch {
                testStatusMessage = "Error: \(error.localizedDescription)"
            }
        }
    }

    private func stopTestRecording() {
        testStatusMessage = "Stopping test recording..."
        Task { @MainActor in
            do {
                let audioData = try await testRecorderService.stopRecording()
                let fileName = "test_recording_\(UUID().uuidString).wav"
                let newURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
                try audioData.write(to: newURL, options: .atomic)
                if let prev = testRecordingURL, prev != newURL { try? FileManager.default.removeItem(at: prev) }
                testRecordingURL = newURL
                testStatusMessage = "Recording saved. Press Play to listen."
            } catch {
                testStatusMessage = "Error: \(error.localizedDescription)"
            }
        }
    }

    private func playTestRecording() {
        guard let url = testRecordingURL else { testStatusMessage = "No recording available"; return }
        do {
            testAudioPlayer = try AVAudioPlayer(contentsOf: url)
            testAudioPlayer?.delegate = AudioPlayerDelegate.shared
            AudioPlayerDelegate.shared.onFinish = { [self] in
                DispatchQueue.main.async { isTestPlaying = false; testStatusMessage = "Playback finished" }
            }
            testAudioPlayer?.play()
            isTestPlaying = true
            testStatusMessage = "Playing recording..."
        } catch {
            testStatusMessage = "Playback error: \(error.localizedDescription)"
        }
    }

    private func stopTestPlayback() {
        testAudioPlayer?.stop()
        testAudioPlayer = nil
        isTestPlaying = false
        testStatusMessage = ""
    }

    private func cleanupTestRecording() {
        testRecorderService.cancelRecording()
        testAudioPlayer?.stop()
        testAudioPlayer = nil
        if let url = testRecordingURL { try? FileManager.default.removeItem(at: url); testRecordingURL = nil }
    }
}

// MARK: - Language Chips

private struct LanguageChipModel: Identifiable {
    let code: String
    let title: String
    let subtitle: String
    let isMuted: Bool
    let source: String

    var id: String {
        "\(source):\(code):\(subtitle)"
    }
}

private struct LanguageChip: View {
    let model: LanguageChipModel

    var body: some View {
        HStack(spacing: 8) {
            Text(model.code.uppercased())
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(model.isMuted ? .secondary : Color("BrandAccentDeep"))
                .frame(width: 30, height: 24)
                .background(
                    model.isMuted ? Color.gray.opacity(0.12) : Color("BrandTintSoft"),
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                )

            VStack(alignment: .leading, spacing: 1) {
                Text(model.title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Text(model.subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .opacity(model.isMuted ? 0.55 : 1)
        .padding(.horizontal, 8)
        .frame(height: 42)
        .background(Color(.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

// MARK: - Translation Pairs

private struct TranslationPairRow: View {
    let pair: TranslationLanguagePair
    let isDefault: Bool
    let isLastUsed: Bool
    let isDisabled: Bool
    let onMakeDefault: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.left.arrow.right")
                .foregroundStyle(isDisabled ? .secondary : Color("BrandAccentDeep"))
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(pair.displayLabel)
                        .font(.system(size: 13, weight: .semibold))
                    if isDefault {
                        Text("Default")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color("BrandTintSoft"), in: Capsule())
                            .foregroundStyle(Color("BrandAccentDeep"))
                    }
                    if isLastUsed, !isDefault {
                        Text("Last used")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Text("\(languageName(pair.languageA)) / \(languageName(pair.languageB))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                onMakeDefault()
            } label: {
                Image(systemName: isDefault ? "checkmark.circle.fill" : "circle")
            }
            .buttonStyle(.plain)
            .disabled(isDisabled || isDefault)
            .help("Make default")

            Button {
                onEdit()
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.plain)
            .disabled(isDisabled)
            .help("Edit pair")

            Button {
                onDelete()
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
            .disabled(isDisabled)
            .help("Remove pair")
        }
        .padding(.horizontal, 10)
        .frame(height: 48)
        .background(Color(.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .opacity(isDisabled ? 0.6 : 1)
    }

    private func languageName(_ code: String) -> String {
        SupportedLanguage.language(for: code)?.name ?? code.uppercased()
    }
}

private struct TranslationPairEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var languageA: String
    @State private var languageB: String

    private let pair: TranslationLanguagePair?
    private let onSave: (TranslationLanguagePair) -> Void

    init(pair: TranslationLanguagePair?, onSave: @escaping (TranslationLanguagePair) -> Void) {
        self.pair = pair
        self.onSave = onSave
        _languageA = State(initialValue: pair?.languageA ?? "en")
        _languageB = State(initialValue: pair?.languageB ?? "uk")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(pair == nil ? "Add Translation Pair" : "Edit Translation Pair")
                .font(.headline)

            Picker("Language A", selection: $languageA) {
                ForEach(SupportedLanguage.cloudLanguages.filter { $0.code != languageB }) { language in
                    Text(language.name).tag(language.code)
                }
            }

            Picker("Language B", selection: $languageB) {
                ForEach(SupportedLanguage.cloudLanguages.filter { $0.code != languageA }) { language in
                    Text(language.name).tag(language.code)
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.escape, modifiers: [])
                Button("Save") {
                    onSave(TranslationLanguagePair(id: pair?.id, languageA: languageA, languageB: languageB))
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(Color("BrandAccentDeep"))
                .disabled(languageA == languageB)
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}

// MARK: - Speech Languages Sheet

private struct SpeechLanguageManagementSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var manualCodes: Set<String>
    @Binding var disabledDetectedCodes: Set<String>

    let detectedLanguages: [KeyboardLanguageDetector.DetectedLanguage]
    let onSave: () -> Void

    @State private var query = ""

    private var filteredLanguages: [SupportedLanguage] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return SupportedLanguage.cloudLanguages }
        return SupportedLanguage.cloudLanguages.filter {
            $0.name.localizedCaseInsensitiveContains(trimmed)
                || $0.code.localizedCaseInsensitiveContains(trimmed)
        }
    }

    private var detectedListHeight: CGFloat {
        min(CGFloat(detectedLanguages.count) * 24, 120)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Speech Languages")
                .font(.headline)

            if !detectedLanguages.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Mac Layouts")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(detectedLanguages) { language in
                                Toggle(isOn: detectedBinding(for: language.code)) {
                                    Text("\(language.code.uppercased()) - \(language.sourceName)")
                                        .lineLimit(1)
                                }
                                .toggleStyle(.checkbox)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .frame(height: detectedListHeight)
                }
            }

            TextField("Search languages", text: $query)
                .textFieldStyle(.roundedBorder)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(filteredLanguages) { language in
                        Toggle(isOn: manualBinding(for: language.code)) {
                            Text("\(language.name) (\(language.code.uppercased()))")
                        }
                        .toggleStyle(.checkbox)
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(minHeight: 220)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.escape, modifiers: [])
                Button("Done") {
                    onSave()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(Color("BrandAccentDeep"))
            }
        }
        .padding(20)
        .frame(width: 430, height: 540)
    }

    private func detectedBinding(for code: String) -> Binding<Bool> {
        Binding(
            get: { !disabledDetectedCodes.contains(code) },
            set: { isEnabled in
                if isEnabled {
                    disabledDetectedCodes.remove(code)
                } else {
                    disabledDetectedCodes.insert(code)
                }
            }
        )
    }

    private func manualBinding(for code: String) -> Binding<Bool> {
        Binding(
            get: { manualCodes.contains(code) },
            set: { isEnabled in
                if isEnabled {
                    manualCodes.insert(code)
                } else {
                    manualCodes.remove(code)
                }
            }
        )
    }
}

// MARK: - Radio Button

struct RadioButton: View {
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Circle()
                .strokeBorder(isSelected ? Color.accentColor : Color.secondary, lineWidth: 2)
                .background(
                    Circle()
                        .fill(isSelected ? Color.accentColor : Color.clear)
                        .padding(3)
                )
                .frame(width: 18, height: 18)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Audio Player Delegate

class AudioPlayerDelegate: NSObject, AVAudioPlayerDelegate {
    static let shared = AudioPlayerDelegate()
    var onFinish: (() -> Void)?

    func audioPlayerDidFinishPlaying(_: AVAudioPlayer, successfully _: Bool) {
        onFinish?()
    }
}
