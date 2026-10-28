import AVFoundation
import SwiftUI

/// "Speaker Labels" in meeting audio settings: voice detection toggle, model download state and the
/// optional voice profile. Design: `docs/design/local-speaker-labels.md` §1–2. Hidden on Intel.
struct SpeakerLabelsSection: View {
    let audioSource: MeetingAudioSource

    @State private var isEnabled = SettingsStorage.shared.speakerIdentificationEnabled
    @State private var profile = VoiceProfileStore.shared.load()
    @State private var isEnrolling = false
    @State private var isConfirmingDelete = false
    private var models = SpeakerModelManager.shared

    var body: some View {
        if !LocalSpeakerDiarizer.isRunningOnIntel {
            Section("Speaker Labels") {
                if LocalSpeakerDiarizer.isSupported {
                    Toggle("Identify speakers (on this Mac)", isOn: $isEnabled)
                        .onChange(of: isEnabled) { _, value in
                            SettingsStorage.shared.speakerIdentificationEnabled = value
                        }
                    caption(
                        "Labels who said what in local transcripts. Runs after Stop, on this Mac only. Your audio never leaves your Mac for this."
                    )
                    if audioSource != .systemPlusMicrophone {
                        caption("Meetings recorded with only one source are labelled by voice only.")
                    }
                    if isEnabled {
                        modelStatus
                        voiceProfileRow
                    }
                } else {
                    Toggle("Identify speakers (on this Mac)", isOn: .constant(false))
                        .disabled(true)
                    caption("Needs macOS 15 or later. Meetings are labelled Me and Others.")
                }
            }
            .sheet(isPresented: $isEnrolling, onDismiss: { profile = VoiceProfileStore.shared.load() }) {
                VoiceEnrollmentView()
            }
            .alert("Delete your voice profile?", isPresented: $isConfirmingDelete) {
                Button("Delete", role: .destructive) {
                    do {
                        try VoiceProfileStore.shared.delete()
                    } catch {
                        Log.app.error("Voice profile delete failed: \(error.localizedDescription, privacy: .public)")
                    }
                    profile = VoiceProfileStore.shared.load()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Diduny will go back to treating the main voice on your microphone as you. Existing transcripts don't change.")
            }
        }
    }

    @ViewBuilder
    private var modelStatus: some View {
        switch models.state {
        case .notDownloaded:
            caption(
                "Needs a one-time download of about \(LocalSpeakerDiarizer.modelDownloadMegabytes) MB, started after your first meeting."
            )
        case .downloading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Downloading speaker model…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .ready:
            EmptyView()
        case .failed:
            HStack {
                Text("Couldn't download the speaker model. Meetings will use Me / Others. Try again later.")
                    .font(.caption)
                    .foregroundStyle(.red)
                Spacer()
                Button("Retry") { models.downloadIfNeeded() }
            }
        }
    }

    private var voiceProfileRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent("Voice profile") {
                HStack {
                    if let profile {
                        Text("Saved \(profile.savedAt.formatted(date: .abbreviated, time: .omitted))")
                            .foregroundStyle(.secondary)
                        Button("Re-record…") { isEnrolling = true }
                        Button("Delete my voice profile", role: .destructive) { isConfirmingDelete = true }
                    } else {
                        Text("Not set up").foregroundStyle(.secondary)
                        Button("Set up…") { isEnrolling = true }
                    }
                }
            }
            caption(
                profile == nil
                    ? "Optional. Helps Diduny tell you from other people at your microphone."
                    : "Stored only on this Mac. Never uploaded."
            )
        }
    }

    private func caption(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

/// Records 10–20 s of the person's voice once and saves only a voice fingerprint (design §2).
struct VoiceEnrollmentView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var recorder = VoiceEnrollmentRecorder()
    private var models = SpeakerModelManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Set up your voice").font(.headline)
            content
        }
        .padding(20)
        .frame(width: 420)
        .onDisappear { recorder.cancel() }
        .onChange(of: models.state) { _, state in
            if state == .ready, recorder.step == .modelNotReady { recorder.step = .ready }
        }
        .onAppear {
            if !LocalSpeakerDiarizer.modelsDownloaded { recorder.step = .modelNotReady }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch recorder.step {
        case .ready:
            instructions
            privacy
            buttons(primary: "Start recording") { recorder.start() }
        case .recording:
            instructions
            ProgressView(value: recorder.level)
                .accessibilityHidden(true)
            HStack {
                Text("\(Int(recorder.elapsed)) of \(Int(VoiceEnrollmentRecorder.targetSeconds)) s")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                ProgressView(value: min(recorder.elapsed / VoiceEnrollmentRecorder.targetSeconds, 1))
            }
            privacy
            buttons(primary: "Stop", primaryDisabled: !recorder.canStop) { recorder.stop() }
        case .tooQuiet:
            Text("Not enough speech. Move closer to the microphone and try again.")
            buttons(primary: "Try again") { recorder.start() }
        case .processing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Saving voice profile…")
            }
        case .success:
            Label("Voice profile saved.", systemImage: "checkmark.circle.fill")
            Text("Diduny will use it to recognise you in future meetings.")
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        case .failure:
            Text("Couldn't create the voice profile. Nothing was saved.")
            buttons(primary: "Try again") { recorder.start() }
        case .micPermission:
            Text("Diduny needs microphone access.")
            buttons(primary: "Open System Settings") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                    NSWorkspace.shared.open(url)
                }
            }
        case .modelNotReady:
            if models.state == .downloading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Downloading speaker model…")
                }
                buttons(primary: "Download", primaryDisabled: true) {}
            } else {
                Text("Speaker model isn't downloaded yet. Download it now (about \(LocalSpeakerDiarizer.modelDownloadMegabytes) MB)?")
                buttons(primary: "Download") { models.downloadIfNeeded() }
            }
        }
    }

    private var instructions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Read this out loud or just talk naturally for 15 seconds.")
            Text("\"Today I'm going to walk through the plan and then we can take questions.\"")
                .italic()
                .textSelection(.enabled)
        }
    }

    private var privacy: some View {
        Text("Only a voice fingerprint is saved on this Mac. The recording is deleted right away and never uploaded.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private func buttons(
        primary: LocalizedStringKey,
        primaryDisabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        HStack {
            Spacer()
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            Button(primary, action: action)
                .keyboardShortcut(.defaultAction)
                .disabled(primaryDisabled)
        }
    }
}

/// Captures the enrollment clip as 16 kHz mono samples in memory; nothing is written to disk.
@Observable
@MainActor
final class VoiceEnrollmentRecorder {
    enum Step: Equatable {
        case ready, recording, tooQuiet, processing, success, failure, micPermission, modelNotReady
    }

    static let targetSeconds: TimeInterval = 15
    static let minimumSeconds: TimeInterval = 10
    static let maximumSeconds: TimeInterval = 20
    /// Speech needed in the clip; less counts as "too quiet".
    static let minimumSpeechSeconds: TimeInterval = 8

    var step: Step = .ready
    private(set) var level: Double = 0
    private(set) var elapsed: TimeInterval = 0
    var canStop: Bool { elapsed >= Self.minimumSeconds }

    private var engine: AVAudioEngine?
    private var samples: [Float] = []
    private var timer: Task<Void, Never>?

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .notDetermined:
            Task {
                if await AVCaptureDevice.requestAccess(for: .audio) { start() } else { step = .micPermission }
            }
            return
        default:
            step = .micPermission
            return
        }

        samples = []
        elapsed = 0
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        ),
            let converter = AVAudioConverter(from: inputFormat, to: outputFormat)
        else {
            step = .failure
            return
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * 16000 / inputFormat.sampleRate) + 32
            guard let converted = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }
            var consumed = false
            converter.convert(to: converted, error: nil) { _, status in
                if consumed {
                    status.pointee = .noDataNow
                    return nil
                }
                consumed = true
                status.pointee = .haveData
                return buffer
            }
            guard let channel = converted.floatChannelData?[0] else { return }
            let chunk = Array(UnsafeBufferPointer(start: channel, count: Int(converted.frameLength)))
            Task { @MainActor in self?.append(chunk) }
        }
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            step = .failure
            return
        }
        self.engine = engine
        step = .recording
        timer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, step == .recording else { return }
                elapsed = Double(samples.count) / 16000
                if elapsed >= Self.maximumSeconds { stop() }
            }
        }
    }

    func stop() {
        guard step == .recording else { return }
        finishCapture()
        let clip = samples
        samples = []
        guard Self.speechSeconds(in: clip) >= Self.minimumSpeechSeconds else {
            step = .tooQuiet
            return
        }
        step = .processing
        Task {
            do {
                guard let embedding = try await LocalSpeakerDiarizer.shared.dominantVoiceEmbedding(samples: clip) else {
                    step = .failure
                    return
                }
                try VoiceProfileStore.shared.save(embedding: embedding)
                step = .success
            } catch {
                Log.app.error("Voice enrollment failed: \(error.localizedDescription, privacy: .public)")
                step = .failure
            }
        }
    }

    func cancel() {
        finishCapture()
        samples = []
    }

    /// Seconds of 100 ms windows loud enough to be speech.
    nonisolated static func speechSeconds(in samples: [Float], sampleRate: Double = 16000) -> TimeInterval {
        let window = Int(sampleRate / 10)
        guard window > 0 else { return 0 }
        var loud = 0
        var start = 0
        while start + window <= samples.count {
            var energy: Float = 0
            for i in start ..< start + window {
                energy += samples[i] * samples[i]
            }
            if sqrt(energy / Float(window)) > 0.01 { loud += 1 }
            start += window
        }
        return Double(loud) / 10
    }

    private func append(_ chunk: [Float]) {
        guard step == .recording else { return }
        samples.append(contentsOf: chunk)
        let rms = sqrt(chunk.reduce(0) { $0 + $1 * $1 } / Float(max(chunk.count, 1)))
        level = min(1, Double(rms) * 8)
    }

    private func finishCapture() {
        timer?.cancel()
        timer = nil
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        level = 0
    }
}
