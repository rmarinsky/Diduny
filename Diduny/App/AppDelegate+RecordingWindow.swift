import AppKit
import SwiftUI

// MARK: - Recording Window (Minimal Pill)

extension AppDelegate {
    func updateRecordingWindow(for state: RecordingState) {
        switch state {
        case .recording, .processing:
            showRecordingWindow()
        case .success:
            updateRecordingWindowContent()
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                self.hideRecordingWindow()
            }
        case .idle, .error:
            hideRecordingWindow()
        }
    }

    func updateRecordingWindowForTranslation(for state: TranslationRecordingState) {
        switch state {
        case .recording, .processing:
            showRecordingWindow()
        case .success:
            updateRecordingWindowContent()
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                self.hideRecordingWindow()
            }
        case .idle, .error:
            hideRecordingWindow()
        }
    }

    func showRecordingWindow() {
        if recordingWindow == nil {
            let contentView = RecordingIndicatorView()
                .environment(appState)

            let hostingView = NSHostingView(rootView: contentView)
            hostingView.frame = NSRect(x: 0, y: 0, width: 200, height: 44)

            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 200, height: 44),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.isOpaque = false
            window.backgroundColor = .clear
            window.level = .floating
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.contentView = hostingView

            // Position near top-center of main screen
            if let screen = NSScreen.main {
                let screenFrame = screen.visibleFrame
                let xPos = screenFrame.midX - 100
                let yPos = screenFrame.maxY - 80
                window.setFrameOrigin(NSPoint(x: xPos, y: yPos))
            }

            recordingWindow = window
        }

        recordingWindow?.orderFront(nil)
    }

    func updateRecordingWindowContent() {
        recordingWindow?.contentView?.needsDisplay = true
    }

    func hideRecordingWindow() {
        recordingWindow?.orderOut(nil)
        recordingWindow = nil
    }
}
