import SwiftUI

struct BatchTranscriptionStatusView: View {
    let item: BatchTranscriptionItem
    let service: FileTranscriptionBatchService
    let onRetry: (UUID) -> Void
    @State private var browserSessions: [BrowserSession]
    @State private var selectedSessionID: String
    @State private var browserOpenError: String?
    @State private var isOpeningBrowser = false

    init(item: BatchTranscriptionItem, service: FileTranscriptionBatchService,
         browserSessions: [BrowserSession]? = nil, onRetry: @escaping (UUID) -> Void) {
        self.item = item
        self.service = service
        self.onRetry = onRetry
        let sessions = browserSessions ?? []
        _browserSessions = State(initialValue: sessions)
        let selected = BrowserSessionStore.selected(
            from: sessions, selectionID: SettingsStorage.shared.selectedBrowserSessionID,
            legacyChromeProfileID: SettingsStorage.shared.selectedChromeProfileID
        )
        _selectedSessionID = State(initialValue: selected?.selectionID ?? SettingsStorage.shared.selectedBrowserSessionID ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if service.isActive(item.id), !item.status.isTerminal {
                    ProgressView()
                        .controlSize(.mini)
                        .accessibilityLabel("Processing \(item.displayName)")
                }
                Text(item.status.displayName)
                    .foregroundStyle(item.status.statusColor)
                    .lineLimit(1)
                if let progress = item.progressFraction, !item.status.isTerminal {
                    Text("\(Int((progress * 100).rounded()))%")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                retryButton
            }
            .font(.caption)

            if service.isActive(item.id),
               !item.status.isTerminal,
               let progress = item.progressFraction
            {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .accessibilityLabel("Progress for \(item.displayName)")
                    .accessibilityValue("\(Int((progress * 100).rounded())) percent")
            }

            if let error = visibleErrorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if item.remoteSource != nil,
               [.authorizationPaused, .failed, .partialResult].contains(item.status) {
                browserRecovery
            }
        }
    }

    private var selectedSession: BrowserSession? {
        browserSessions.first { $0.selectionID == selectedSessionID }
    }

    private var browserRecovery: some View {
        VStack(alignment: .leading, spacing: 6) {
            if browserSessions.isEmpty {
                Text("No supported browser was found. Install or open a browser, then refresh the list.")
                    .font(.caption)
            } else {
                Picker("Browser and profile", selection: $selectedSessionID) {
                    ForEach(browserSessions, id: \.selectionID) { session in
                        Text(session.displayName).tag(session.selectionID)
                    }
                }
                .onChange(of: selectedSessionID) { _, value in
                    SettingsStorage.shared.selectedBrowserSessionID = value
                    browserOpenError = nil
                }
                .disabled(service.isProcessing)
            }
            HStack {
                Button("Open YouTube") {
                    guard let session = selectedSession, let source = item.remoteSource else { return }
                    isOpeningBrowser = true
                    browserOpenError = nil
                    Task { @MainActor in
                        defer { isOpeningBrowser = false }
                        do { try await session.openYouTube(source) }
                        catch { browserOpenError = error.localizedDescription }
                    }
                }
                .disabled(selectedSession == nil || isOpeningBrowser)
                Button("Check access") {
                    guard let session = selectedSession else { return }
                    SettingsStorage.shared.selectedBrowserSessionID = session.selectionID
                    browserOpenError = nil
                    if item.status == .authorizationPaused,
                       service.items.contains(where: { $0.id == item.id }) {
                        service.retryAuthorization()
                    } else {
                        onRetry(item.id)
                    }
                }
                .disabled(selectedSession == nil || service.isProcessing)
                Button {
                    refreshBrowserSessions()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh browser profiles")
                .accessibilityLabel("Refresh browser profiles")
            }
            .controlSize(.small)
            if let browserOpenError {
                Text(browserOpenError).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.caption)
        .onAppear {
            if browserSessions.isEmpty { refreshBrowserSessions() }
        }
    }

    private func refreshBrowserSessions() {
        browserSessions = BrowserSessionStore.discover()
        if selectedSession == nil { selectedSessionID = browserSessions.first?.selectionID ?? "" }
    }

    private var visibleErrorMessage: String? {
        item.errorMessage
            ?? (service.items.contains(where: { $0.id == item.id }) ? service.batchError : nil)
    }

    @ViewBuilder
    private var retryButton: some View {
        switch item.status {
        case .failed where item.remoteSource != nil, .partialResult where item.remoteSource != nil:
            EmptyView()
        case .failed, .cancelled, .partialResult:
            Button("Retry") { onRetry(item.id) }
                .controlSize(.mini)
        case .authorizationPaused:
            EmptyView()
        default:
            EmptyView()
        }
    }
}

private extension BatchTranscriptionItem.Status {
    var statusColor: Color {
        switch self {
        case .authorizationPaused, .partialResult: .orange
        case .failed: .red
        default: .secondary
        }
    }

    var displayName: String {
        switch self {
        case .queued: String(localized: "Queued")
        case .checkingLink: String(localized: "Checking link…")
        case .checkingDuplicate: String(localized: "Checking duplicate…")
        case .retrievingCaptions: String(localized: "Retrieving captions…")
        case .downloading: String(localized: "Downloading audio…")
        case .preparing: String(localized: "Preparing audio…")
        case .uploading: String(localized: "Uploading…")
        case .processing: String(localized: "Transcribing…")
        case .finalizing: String(localized: "Finishing…")
        case .completed: String(localized: "Completed")
        case .partialResult: String(localized: "Partial result")
        case .duplicate: String(localized: "Transcript reused")
        case .authorizationPaused: String(localized: "Authorization paused")
        case .failed: String(localized: "Failed")
        case .cancelled: String(localized: "Cancelled")
        }
    }
}
