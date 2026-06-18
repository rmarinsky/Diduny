import AppKit
import SwiftUI

@MainActor
final class TextTranslationWindowController: NSObject, NSWindowDelegate {
    static let shared = TextTranslationWindowController()

    private var panel: NSPanel?
    private var eventMonitor: Any?
    private var viewModel: TextTranslationViewModel?

    private override init() {
        super.init()
    }

    func showWindow(sourceText: String) {
        // If window exists, update the view model and bring to front
        if let panel, panel.isVisible, let viewModel {
            viewModel.sourceText = sourceText
            viewModel.translatedText = ""
            viewModel.errorMessage = nil
            viewModel.showCopiedConfirmation = false
            viewModel.updateDetectedLanguage()
            viewModel.translate()
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        closeWindow()

        let vm = TextTranslationViewModel(sourceText: sourceText)
        viewModel = vm
        vm.translate()

        let view = TextTranslationView(viewModel: vm) { [weak self] in
            self?.closeWindow()
        }
        let hostingView = NSHostingView(rootView: view)

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 450),
            styleMask: [.titled, .closable, .hudWindow, .utilityWindow, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.title = "Translate"
        panel.contentView = hostingView
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.isMovableByWindowBackground = true
        panel.becomesKeyOnlyIfNeeded = false

        panel.center()

        panel.delegate = self
        self.panel = panel
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { // Escape
                self?.closeWindow()
                return nil
            }
            return event
        }
    }

    func closeWindow() {
        panel?.close()
        cleanupMonitor()
        panel = nil
        viewModel = nil
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor in
            cleanupMonitor()
            panel = nil
            viewModel = nil
        }
    }

    private func cleanupMonitor() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }
}

@MainActor
final class TranslationTargetPickerWindowController: NSObject, NSWindowDelegate {
    static let shared = TranslationTargetPickerWindowController()

    private var panel: NSPanel?
    private var eventMonitor: Any?

    private override init() {
        super.init()
    }

    func show(
        selectedCode: String,
        allowsNonEnglishTargets: Bool,
        onSelect: @escaping (String) -> Void,
        onManage: @escaping () -> Void
    ) {
        let pair = SettingsStorage.shared.translationLanguagePairs.first { $0.contains(selectedCode) }
            ?? SettingsStorage.shared.defaultTranslationLanguagePair
        show(
            selectedPairID: pair.id,
            allowsNonEnglishTargets: allowsNonEnglishTargets,
            onSelectPair: { selectedPair in
                onSelect(selectedPair.languageB)
            },
            onManage: onManage
        )
    }

    func show(
        selectedPairID: String?,
        allowsNonEnglishTargets: Bool,
        onSelectPair: @escaping (TranslationLanguagePair) -> Void,
        onManage: @escaping () -> Void
    ) {
        closeWindow()

        let pairs = SettingsStorage.shared.translationLanguagePairs
        let initialPair = selectedPairID.flatMap { id in pairs.first(where: { $0.id == id }) }
            ?? SettingsStorage.shared.resolveTranslationLanguagePair()
        let view = TranslationPairPickerView(
            initialSelectedPairID: initialPair.id,
            allowsNonEnglishTargets: allowsNonEnglishTargets,
            onSelect: { [weak self] pair in
                self?.closeWindow()
                onSelectPair(pair)
            },
            onManage: { [weak self] in
                self?.closeWindow()
                onManage()
            },
            onCancel: { [weak self] in
                self?.closeWindow()
            }
        )

        let hostingView = NSHostingView(rootView: view)
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 430),
            styleMask: [.titled, .closable, .hudWindow, .utilityWindow, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.title = "Translation Pair"
        panel.contentView = hostingView
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.isMovableByWindowBackground = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.center()
        panel.delegate = self
        self.panel = panel

        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {
                self?.closeWindow()
                return nil
            }
            return event
        }
    }

    func closeWindow() {
        panel?.close()
        cleanupMonitor()
        panel = nil
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor in
            cleanupMonitor()
            panel = nil
        }
    }

    private func cleanupMonitor() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }
}

private struct TranslationPairPickerView: View {
    let allowsNonEnglishTargets: Bool
    let onSelect: (TranslationLanguagePair) -> Void
    let onManage: () -> Void
    let onCancel: () -> Void

    @State private var selectedPairID: String

    init(
        initialSelectedPairID: String,
        allowsNonEnglishTargets: Bool,
        onSelect: @escaping (TranslationLanguagePair) -> Void,
        onManage: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.allowsNonEnglishTargets = allowsNonEnglishTargets
        self.onSelect = onSelect
        self.onManage = onManage
        self.onCancel = onCancel
        _selectedPairID = State(initialValue: initialSelectedPairID)
    }

    private var pairs: [TranslationLanguagePair] {
        SettingsStorage.shared.translationLanguagePairs
    }

    private var selectedPair: TranslationLanguagePair? {
        pairs.first(where: { $0.id == selectedPairID }) ?? pairs.first
    }

    private var effectivePair: TranslationLanguagePair {
        selectedPair ?? TranslationLanguagePair.defaultPair
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(pairs) { pair in
                        pairRow(pair)
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(minHeight: 220)

            if !allowsNonEnglishTargets {
                Label("Local Whisper translates to English only.", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button("Manage...") {
                    onManage()
                }

                Spacer()

                Button("Cancel") {
                    onCancel()
                }
                .keyboardShortcut(.escape, modifiers: [])

                Button("Start Recording") {
                    onSelect(effectivePair)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color("BrandAccentDeep"))
                .keyboardShortcut(.return, modifiers: [])
                .disabled(!isEnabled(effectivePair))
            }
        }
        .padding(16)
        .frame(width: 380, height: 430)
        .onAppear {
            if !isEnabled(effectivePair),
               let englishPair = pairs.first(where: { $0.contains("en") }) {
                selectedPairID = englishPair.id
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "globe")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Color("BrandAccentDeep"))
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text("Translate speech between")
                    .font(.system(size: 15, weight: .semibold))
                Text(effectivePair.displayLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
    }

    private func pairRow(_ pair: TranslationLanguagePair) -> some View {
        let selected = pair.id == selectedPairID
        let enabled = isEnabled(pair)

        return Button {
            guard enabled else { return }
            selectedPairID = pair.id
        } label: {
            HStack(spacing: 10) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? Color("BrandAccentDeep") : .secondary)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 1) {
                    Text(pair.displayLabel)
                        .font(.system(size: 13, weight: selected ? .semibold : .regular))
                        .foregroundStyle(enabled ? .primary : .secondary)
                    Text("\(languageName(pair.languageA)) / \(languageName(pair.languageB))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                Spacer()

                if !enabled {
                    Text("Cloud")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 40)
            .background(
                selected ? Color("BrandTintSoft") : Color.clear,
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    private func isEnabled(_ pair: TranslationLanguagePair) -> Bool {
        allowsNonEnglishTargets || pair.contains("en")
    }

    private func languageName(_ code: String) -> String {
        SupportedLanguage.language(for: code)?.name ?? code.uppercased()
    }
}
