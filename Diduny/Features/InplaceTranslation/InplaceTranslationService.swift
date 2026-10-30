import AppKit
import NaturalLanguage

/// Snapshot of the general pasteboard so the user's clipboard survives the capture/paste round trip.
struct PasteboardSnapshot {
    private let items: [[NSPasteboard.PasteboardType: Data]]

    static func capture(from pasteboard: NSPasteboard = .general) -> PasteboardSnapshot {
        let items = (pasteboard.pasteboardItems ?? []).map { item in
            item.types.reduce(into: [NSPasteboard.PasteboardType: Data]()) { result, type in
                if let data = item.data(forType: type) { result[type] = data }
            }
        }
        return PasteboardSnapshot(items: items)
    }

    func restore(to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        let restored = items.map { entry -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in entry {
                item.setData(data, forType: type)
            }
            return item
        }
        if !restored.isEmpty { pasteboard.writeObjects(restored) }
    }
}

/// Double-tap ⌥⌘ flow: capture selection, translate, paste over it, restore the clipboard.
/// Never logs the selected text or the translation.
@MainActor
final class InplaceTranslationService {
    static let shared = InplaceTranslationService()

    enum FlowError: Error {
        case timeout
    }

    static let badgeDelay: Duration = .zero
    static let translationTimeoutSeconds: Double = 8

    /// Picks the direction within the default pair: text detected as one pair language goes to the other.
    /// Detection is constrained to the pair, so the result is always A→B or B→A.
    nonisolated static func direction(for text: String, pair: TranslationLanguagePair) -> (source: String, target: String) {
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = pair.codes.map { NLLanguage(rawValue: $0) }
        recognizer.processString(text)
        let detected = recognizer.dominantLanguage?.rawValue
        let source = pair.contains(detected) ? (SupportedLanguage.normalizedCode(detected) ?? pair.languageA) : pair.languageA
        return (source, pair.opposite(of: source) ?? pair.languageB)
    }
    private static let clipboardRestoreDelay: Duration = .milliseconds(400)

    private var isRunning = false

    private init() {}

    nonisolated static func toast(for error: Error) -> InplaceTranslationToast {
        if case TranslationError.quotaExceeded = error { return .quotaFailure }
        return .networkFailure
    }

    nonisolated static func withTimeout<T: Sendable>(
        seconds: Double,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask(operation: operation)
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw FlowError.timeout
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw FlowError.timeout }
            return first
        }
    }

    func run() async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }

        guard ClipboardService.isAccessibilityGranted() else {
            PermissionManager.shared.showPermissionAlert(for: .accessibility)
            return
        }

        let feedback = InplaceTranslationFeedbackController.shared
        let selectionEnd = await Task.detached { InplaceTranslationAnchor.selectionEndRect() }.value
        let snapshot = PasteboardSnapshot.capture()

        let source: String
        do {
            source = try await ClipboardService.shared.captureSelectedText()
        } catch ClipboardError.accessibilityNotGranted {
            PermissionManager.shared.showPermissionAlert(for: .accessibility)
            return
        } catch {
            snapshot.restore()
            Log.app.info("[InplaceTranslation] No selection captured")
            feedback.showToast(.nothingSelected, selectionEnd: selectionEnd)
            return
        }

        let (sourceLanguage, target) = Self.direction(
            for: source, pair: SettingsStorage.shared.defaultTranslationLanguagePair
        )
        let badgeTask = Task { @MainActor in
            try? await Task.sleep(for: Self.badgeDelay)
            guard !Task.isCancelled else { return }
            feedback.showBadge(selectionEnd: selectionEnd)
        }

        do {
            let translated = try await Self.withTimeout(seconds: Self.translationTimeoutSeconds) {
                try await TextTranslationClient.requestTranslation(
                    sourceText: source, sourceLanguage: sourceLanguage, targetLanguage: target
                )
            }
            badgeTask.cancel()
            await feedback.finishBadge(success: true)

            ClipboardService.shared.copy(text: translated)
            let changeCount = NSPasteboard.general.changeCount
            try await ClipboardService.shared.paste()
            Task { await feedback.dismissBadge() }

            // Give the target app time to read the pasteboard before restoring it.
            try? await Task.sleep(for: Self.clipboardRestoreDelay)
            if NSPasteboard.general.changeCount == changeCount { snapshot.restore() }
            Log.app.info("[InplaceTranslation] Replaced selection (\(source.count) chars)")
        } catch {
            badgeTask.cancel()
            snapshot.restore()
            Log.app.error("[InplaceTranslation] Failed: \(String(describing: type(of: error)), privacy: .public)")
            await feedback.finishBadge(success: false)
            await feedback.dismissBadge()
            feedback.showToast(Self.toast(for: error), selectionEnd: selectionEnd)
        }
    }
}
