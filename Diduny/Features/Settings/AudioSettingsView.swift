import SwiftUI

/// Settings > Audio (design-spec 7.14, changes/05 §2.4): devices and levels only. Engines, silence,
/// suggestions and languages moved to Modes and Languages (05 §1.C, §1.D).
struct AudioSettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(AudioDeviceManager.self) private var deviceManager

    @StateObject private var micRecorder = AudioRecorderService()
    @State private var micPlayback = AudioTestPlayback()
    @State private var micClipURL: URL?
    @State private var micStatus = ""
    @State private var systemTester = SystemAudioTester()

    @State private var audioSource = SettingsStorage.shared.meetingAudioSource
    @State private var micGain = SettingsStorage.shared.meetingMicGain
    @State private var systemGain = SettingsStorage.shared.meetingSystemGain

    var body: some View {
        PageScaffold(title: "Audio", subtitle: "Devices and levels.") {
            EmptyView()
        } content: {
            VStack(alignment: .leading, spacing: 0) {
                AudioSettingsGroup(title: "Microphone") {
                    inputRow
                    micTestRow
                }
                AudioSettingsGroup(title: "Meetings") {
                    sourceRow
                    if AudioSettingsText.showsMicrophoneLevel(audioSource) {
                        gainRow("Microphone level", value: $micGain, identifier: "audio.meeting.micLevel") {
                            SettingsStorage.shared.meetingMicGain = $0
                        }
                    }
                    gainRow("System audio level", value: $systemGain, identifier: "audio.meeting.systemLevel") {
                        SettingsStorage.shared.meetingSystemGain = $0
                    }
                    systemTestRow
                }
                SpeakerLabelsGroup()
            }
        }
        .onAppear {
            audioSource = SettingsStorage.shared.meetingAudioSource
            micGain = SettingsStorage.shared.meetingMicGain
            systemGain = SettingsStorage.shared.meetingSystemGain
            micPlayback.onFinish = { micStatus = String(localized: "Playback finished") }
        }
        .onDisappear {
            cleanUpMicTest()
            systemTester.cleanUp()
        }
    }

    // MARK: - Microphone

    private var inputRow: some View {
        SettingsLineRow(title: "Input", kind: .popUp) {
            Picker("Input", selection: inputSelection) {
                Text("System Default").tag(String?.none)
                ForEach(deviceManager.availableDevices) { device in
                    Text(verbatim: device.name).tag(String?.some(device.uid))
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .accessibilityIdentifier("audio.input")
        }
    }

    /// A stale preferred device (unplugged) reads as System Default, as today.
    private var inputSelection: Binding<String?> {
        Binding(
            get: { deviceManager.effectiveDeviceUID(preferred: appState.preferredDeviceUID) },
            set: { appState.preferredDeviceUID = $0 }
        )
    }

    private var micTestRow: some View {
        SettingsLineRow(title: "Test the microphone", caption: statusCaption(micStatus), kind: .button) {
            AudioLevelBar(level: micRecorder.isRecording ? micRecorder.audioLevel : 0)
            Button(micRecorder.isRecording ? "Stop Recording" : "Record") {
                if micRecorder.isRecording { stopMicTest() } else { startMicTest() }
            }
            .buttonStyle(.bordered)
            .disabled(micPlayback.isPlaying)
            .accessibilityIdentifier("audio.mic.record")
            Button(micPlayback.isPlaying ? "Stop" : "Play") { toggleMicPlayback() }
                .buttonStyle(.bordered)
                .disabled(micClipURL == nil || micRecorder.isRecording)
                .accessibilityIdentifier("audio.mic.play")
        }
    }

    // MARK: - Meetings

    private var sourceRow: some View {
        SettingsLineRow(title: "Record", kind: .segmented) {
            Picker("Record", selection: $audioSource) {
                Text("System audio only").tag(MeetingAudioSource.systemOnly)
                Text("System + microphone").tag(MeetingAudioSource.systemPlusMicrophone)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .accessibilityIdentifier("audio.meeting.source")
            .onChange(of: audioSource) { _, value in SettingsStorage.shared.meetingAudioSource = value }
        }
    }

    private func gainRow(
        _ title: LocalizedStringKey,
        value: Binding<Float>,
        identifier: String,
        save: @escaping (Float) -> Void
    ) -> some View {
        SettingsLineRow(title: title) {
            Slider(value: value, in: 0 ... 2, step: 0.05) { editing in
                if !editing { save(value.wrappedValue) }
            }
            .labelsHidden()
            .tint(DS.Palette.accent)
            .frame(width: 129)
            .accessibilityLabel(Text(title))
            .accessibilityIdentifier(identifier)
            Text(verbatim: AudioSettingsText.gainPercent(value.wrappedValue))
                .font(DS.Font.meta)
                .foregroundStyle(DS.Palette.secondary)
                .monospacedDigit()
                .frame(minWidth: 36, alignment: .trailing)
                .accessibilityIdentifier("\(identifier).value")
        }
    }

    private var systemTestRow: some View {
        SettingsLineRow(
            title: "Test system audio",
            caption: statusCaption(systemTester.status),
            kind: .button,
            showsHairline: false
        ) {
            Button(systemTester.isCapturing ? "Stop Capture" : "Capture") {
                Task { await systemTester.toggleCapture() }
            }
            .buttonStyle(.bordered)
            .disabled(systemTester.playback.isPlaying)
            .accessibilityIdentifier("audio.meeting.capture")
            Button(systemTester.playback.isPlaying ? "Stop" : "Play") { systemTester.togglePlayback() }
                .buttonStyle(.bordered)
                .disabled(systemTester.clipURL == nil || systemTester.isCapturing)
                .accessibilityIdentifier("audio.meeting.play")
        }
    }

    // MARK: - Microphone test

    /// Status lines from the tests are already localized; interpolation keeps them verbatim.
    private func statusCaption(_ status: String) -> LocalizedStringKey? {
        status.isEmpty ? nil : "\(status)"
    }

    private func startMicTest() {
        let (device, _) = deviceManager.resolveDevice(preferredUID: appState.preferredDeviceUID)
        micStatus = String(localized: "Recording... speak into your microphone")
        Task { @MainActor in
            do {
                try await micRecorder.startRecording(device: device)
            } catch {
                micStatus = String(localized: "Error: \(error.localizedDescription)")
            }
        }
    }

    private func stopMicTest() {
        Task { @MainActor in
            do {
                let data = try await micRecorder.stopRecording()
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("test_recording_\(UUID().uuidString).wav")
                try data.write(to: url, options: .atomic)
                if let micClipURL { try? FileManager.default.removeItem(at: micClipURL) }
                micClipURL = url
                micStatus = String(localized: "Recording saved. Press Play to listen.")
            } catch {
                micStatus = String(localized: "Error: \(error.localizedDescription)")
            }
        }
    }

    private func toggleMicPlayback() {
        if micPlayback.isPlaying {
            micPlayback.stop()
            micStatus = ""
            return
        }
        guard let micClipURL else { return }
        do {
            try micPlayback.play(micClipURL)
            micStatus = String(localized: "Playing recording...")
        } catch {
            micStatus = String(localized: "Playback error: \(error.localizedDescription)")
        }
    }

    private func cleanUpMicTest() {
        micRecorder.cancelRecording()
        micPlayback.stop()
        if let micClipURL { try? FileManager.default.removeItem(at: micClipURL) }
        micClipURL = nil
    }
}

/// A Settings group (design-spec 4.10): heading 15 semibold, then rows; 18 above each group.
struct AudioSettingsGroup<Content: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(DS.Font.groupHeading)
                .foregroundStyle(DS.Palette.text)
                .accessibilityAddTraits(.isHeader)
                .padding(.bottom, DS.Space.xs)
            content()
        }
        .padding(.top, 18)
    }
}

/// Microphone level bar (spec 7.14): 90 x 6, `chip` track, `ok` fill, radius 3. Follows the
/// input level with no easing; empty unless a test recording runs.
struct AudioLevelBar: View {
    let level: Float

    var body: some View {
        let fraction = AudioSettingsText.levelFraction(level)
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: DS.Radius.levelBar, style: .continuous)
                .fill(DS.Palette.chip)
            RoundedRectangle(cornerRadius: DS.Radius.levelBar, style: .continuous)
                .fill(DS.Palette.ok)
                .frame(width: 90 * fraction)
        }
        .frame(width: 90, height: 6)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.levelBar, style: .continuous))
        .accessibilityElement()
        .accessibilityAddTraits(.isImage)
        .accessibilityLabel(Text("Input level"))
        .accessibilityValue(Text(verbatim: "\(Int((fraction * 100).rounded()))%"))
        .accessibilityIdentifier("audio.mic.level")
    }
}
