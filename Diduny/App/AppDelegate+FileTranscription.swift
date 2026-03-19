import AppKit
import AVFoundation
import Foundation
import UniformTypeIdentifiers

// MARK: - File Transcription

extension AppDelegate {
    func transcribeFile() {
        let panel = NSOpenPanel()
        panel.title = "Select Audio File to Transcribe"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [
            .audio,
            .mpeg4Audio,
            .mp3,
            .wav,
            .aiff,
            UTType("org.xiph.flac") ?? .audio,
            UTType("public.ogg-audio") ?? .audio,
            .mpeg4Movie,
            .movie,
        ]

        NSApp.activate(ignoringOtherApps: true)

        guard panel.runModal() == .OK, let fileURL = panel.url else {
            return
        }

        Task {
            await processFileTranscription(fileURL: fileURL)
        }
    }

    private func processFileTranscription(fileURL: URL) async {
        Log.app.info("transcribeFile: BEGIN - \(fileURL.lastPathComponent)")

        await MainActor.run {
            appState.recordingState = .processing
            NotchManager.shared.startProcessing(mode: .fileTranscription)
        }

        do {
            let audioData = try await loadAudioData(from: fileURL)
            Log.app.info("transcribeFile: Loaded \(audioData.count) bytes")

            let service = activeTranscriptionService

            let text = try await service.transcribe(audioData: audioData)
            Log.app.info("transcribeFile: Transcription received (\(text.count) chars)")

            clipboardService.copy(text: text)

            if SettingsStorage.shared.autoPaste {
                do {
                    try await clipboardService.paste()
                } catch ClipboardError.accessibilityNotGranted {
                    PermissionManager.shared.showPermissionAlert(for: .accessibility)
                } catch {
                    Log.app.error("transcribeFile: Paste failed - \(error.localizedDescription)")
                }
            }

            await MainActor.run {
                appState.lastTranscription = text
                appState.isEmptyTranscription = false
                appState.recordingState = .success
                appState.recordingStartTime = nil
                if let text = appState.lastTranscription {
                    NotchManager.shared.showSuccess(text: text)
                }
            }

            // Auto-reset to idle
            voiceAutoResetTask?.cancel()
            voiceAutoResetTask = Task {
                try? await Task.sleep(for: .seconds(1.5))
                guard !Task.isCancelled else { return }
                if appState.recordingState == .success {
                    appState.recordingState = .idle
                }
            }

            // Calculate actual audio duration
            let asset = AVURLAsset(url: fileURL)
            let duration = try await asset.load(.duration)
            let durationSeconds = CMTimeGetSeconds(duration)

            // Save to recordings library (copy original file to preserve format)
            RecordingsLibraryStorage.shared.saveRecording(
                audioURL: fileURL,
                type: .fileTranscription,
                duration: durationSeconds.isFinite ? durationSeconds : 0,
                transcriptionText: text
            )

            if SettingsStorage.shared.playSoundOnCompletion {
                NSSound(named: .init("Funk"))?.play()
            }

        } catch is CancellationError {
            Log.app.info("transcribeFile: Cancelled")
            await MainActor.run {
                appState.recordingState = .idle
                appState.recordingStartTime = nil
                NotchManager.shared.hide()
            }
            return
        } catch {
            Log.app.error("transcribeFile: ERROR - \(error.localizedDescription)")

            let isEmptyTranscription: Bool = {
                guard case .emptyTranscription = error as? TranscriptionError else { return false }
                return true
            }()

            await MainActor.run {
                appState.errorMessage = error.localizedDescription
                appState.isEmptyTranscription = isEmptyTranscription
                appState.recordingState = .error
                NotchManager.shared.showError(message: error.localizedDescription)
            }

            // Auto-reset error to idle
            voiceAutoResetTask?.cancel()
            voiceAutoResetTask = Task {
                try? await Task.sleep(for: .seconds(2.0))
                guard !Task.isCancelled else { return }
                if appState.recordingState == .error {
                    appState.recordingState = .idle
                }
            }
        }

        Log.app.info("transcribeFile: END")
    }
}
