import NaturalLanguage
import SwiftUI

// MARK: - Translation Error

private enum TranslationError: LocalizedError {
    case invalidRequest
    case requestFailed(String)
    case emptyResult

    var errorDescription: String? {
        switch self {
        case .invalidRequest:
            "Failed to prepare translation request"
        case let .requestFailed(message):
            "Translation failed: \(message)"
        case .emptyResult:
            "Translation returned an empty result"
        }
    }
}

// MARK: - Translation Response

private struct TranslationResponse: Decodable {
    struct Sentence: Decodable {
        let trans: String?
    }

    let sentences: [Sentence]
    let src: String?
}

// MARK: - View Model

@MainActor
final class TextTranslationViewModel: ObservableObject {
    @Published var sourceText: String
    @Published var translatedText: String = ""
    @Published var sourceLanguageCode: String
    @Published var targetLanguageCode: String
    @Published var detectedLanguageName: String = ""
    @Published var detectedLanguageCode: String?
    @Published var isTranslating: Bool = false
    @Published var errorMessage: String?
    @Published var showCopiedConfirmation: Bool = false

    private var translationTask: Task<Void, Never>?
    private var copiedConfirmationTask: Task<Void, Never>?

    deinit {
        translationTask?.cancel()
        copiedConfirmationTask?.cancel()
    }

    init(sourceText: String) {
        self.sourceText = sourceText
        sourceLanguageCode = SettingsStorage.shared.textTranslationSourceLanguage
        targetLanguageCode = SettingsStorage.shared.textTranslationTargetLanguage
        updateDetectedLanguage()
    }

    func translate() {
        guard !sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        isTranslating = true
        errorMessage = nil
        translatedText = ""
        showCopiedConfirmation = false

        translationTask?.cancel()
        translationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await Self.requestTranslation(
                    sourceText: self.sourceText,
                    sourceLanguage: self.sourceLanguageCode,
                    targetLanguage: self.targetLanguageCode
                )
                guard !Task.isCancelled else { return }
                self.translatedText = result
                self.isTranslating = false

                // Auto-copy to clipboard
                self.copyTranslation()
            } catch is CancellationError {
                self.isTranslating = false
            } catch {
                self.errorMessage = error.localizedDescription
                self.isTranslating = false
            }
        }
    }

    func updateDetectedLanguage() {
        let detectedCode = Self.detectLanguageCode(for: sourceText)
        detectedLanguageCode = SettingsStorage.normalizedLanguageCode(detectedCode)
        detectedLanguageName = Self.languageDisplayName(for: detectedCode)
    }

    func persistSourceLanguage() {
        SettingsStorage.shared.textTranslationSourceLanguage = sourceLanguageCode
    }

    func persistTargetLanguage() {
        SettingsStorage.shared.textTranslationTargetLanguage = targetLanguageCode
    }

    func copyTranslation() {
        guard !translatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        ClipboardService.shared.copy(text: translatedText)
        showCopiedConfirmation = true
        copiedConfirmationTask?.cancel()
        copiedConfirmationTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.showCopiedConfirmation = false
        }
    }

    var canSwapLanguagesAndText: Bool {
        effectiveSourceLanguageCode != nil
            && !translatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func swapLanguagesAndText() {
        guard let sourceTarget = effectiveSourceLanguageCode else { return }

        let previousSourceText = sourceText
        sourceText = translatedText
        translatedText = previousSourceText

        let previousTarget = targetLanguageCode
        sourceLanguageCode = previousTarget
        targetLanguageCode = sourceTarget
        persistSourceLanguage()
        persistTargetLanguage()
        updateDetectedLanguage()
    }

    private var effectiveSourceLanguageCode: String? {
        if sourceLanguageCode == "auto" {
            return detectedLanguageCode
        }
        return SettingsStorage.normalizedLanguageCode(sourceLanguageCode)
    }

    // MARK: - Language Detection

    private static func detectLanguageCode(for text: String) -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        return recognizer.dominantLanguage?.rawValue
    }

    private static func languageDisplayName(for code: String?) -> String {
        guard let code else { return "Unknown" }
        return SupportedLanguage.language(for: code)?.name
            ?? Locale.current.localizedString(forLanguageCode: code)?.capitalized
            ?? code.uppercased()
    }

    // MARK: - Translation API

    private static func requestTranslation(
        sourceText: String,
        sourceLanguage: String,
        targetLanguage: String
    ) async throws -> String {
        let settings = SettingsStorage.shared
        let proxyBase = settings.proxyBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let translateURL = "\(proxyBase)/api/v1/translations"

        guard var components = URLComponents(string: translateURL) else {
            throw TranslationError.invalidRequest
        }

        components.queryItems = [
            URLQueryItem(name: "q", value: sourceText),
            URLQueryItem(name: "tl", value: targetLanguage),
            URLQueryItem(name: "sl", value: normalizedSourceLanguage(sourceLanguage)),
        ]

        guard let url = components.url else {
            throw TranslationError.invalidRequest
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20

        await AuthService.shared.authenticatedRequest(&request)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw TranslationError.requestFailed("invalid response")
        }

        guard httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "status \(httpResponse.statusCode)"
            throw TranslationError.requestFailed(errorBody)
        }

        let payload = try JSONDecoder().decode(TranslationResponse.self, from: data)
        let translatedText = payload.sentences
            .compactMap(\.trans)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !translatedText.isEmpty else {
            throw TranslationError.emptyResult
        }

        return translatedText
    }

    private static func normalizedSourceLanguage(_ code: String) -> String {
        if code == "auto" { return "auto" }
        return SettingsStorage.normalizedLanguageCode(code) ?? "auto"
    }
}

// MARK: - View

struct TextTranslationView: View {
    @ObservedObject var viewModel: TextTranslationViewModel
    var onClose: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            languageControls

            // Source text
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Source")
                        .font(.headline)

                    if viewModel.sourceLanguageCode == "auto", !viewModel.detectedLanguageName.isEmpty {
                        Text(viewModel.detectedLanguageName)
                            .font(.caption)
                            .foregroundColor(Color("BrandAccentDeep"))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color("BrandAccentDeep").opacity(0.10)))
                    }

                    Spacer()
                }

                TextEditor(text: $viewModel.sourceText)
                    .font(.body)
                    .frame(minHeight: 80, maxHeight: 120)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
                    .onChange(of: viewModel.sourceText) { _, _ in
                        viewModel.updateDetectedLanguage()
                    }
            }

            // Translation result
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Translation")
                        .font(.headline)

                    Spacer()

                    if viewModel.showCopiedConfirmation {
                        Text("Copied to clipboard")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .transition(.opacity)
                    }

                    Button {
                        viewModel.copyTranslation()
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                    .disabled(viewModel.translatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                TextEditor(text: $viewModel.translatedText)
                    .font(.body)
                    .frame(minHeight: 80, maxHeight: 120)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))

                if let error = viewModel.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                }
            }
        }
        .padding(20)
        .frame(width: 540, height: 450)
        .animation(.easeInOut(duration: 0.2), value: viewModel.showCopiedConfirmation)
    }

    private var languageControls: some View {
        HStack(spacing: 10) {
            Picker("From:", selection: $viewModel.sourceLanguageCode) {
                Text("Auto").tag("auto")
                ForEach(SupportedLanguage.cloudLanguages) { language in
                    Text(language.name).tag(language.code)
                }
            }
            .frame(maxWidth: 190)
            .onChange(of: viewModel.sourceLanguageCode) { _, _ in
                viewModel.persistSourceLanguage()
            }

            Button {
                viewModel.swapLanguagesAndText()
            } label: {
                Image(systemName: "arrow.left.arrow.right")
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.bordered)
            .help("Swap languages and text")
            .disabled(!viewModel.canSwapLanguagesAndText)

            Picker("To:", selection: $viewModel.targetLanguageCode) {
                ForEach(targetLanguages) { language in
                    Text(language.name).tag(language.code)
                }
            }
            .frame(maxWidth: 190)
            .onChange(of: viewModel.targetLanguageCode) { _, _ in
                viewModel.persistTargetLanguage()
            }

            Spacer(minLength: 0)

            if viewModel.isTranslating {
                ProgressView()
                    .controlSize(.small)
            }

            Button(action: viewModel.translate) {
                Text("Translate")
                    .frame(minWidth: 80)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color("BrandAccentDeep"))
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(viewModel.isTranslating || viewModel.sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private var targetLanguages: [SupportedLanguage] {
        var languages = SettingsStorage.shared.translationTargetLanguages.compactMap {
            SupportedLanguage.language(for: $0)
        }
        if !languages.contains(where: { $0.code == viewModel.targetLanguageCode }),
           let selected = SupportedLanguage.language(for: viewModel.targetLanguageCode)
        {
            languages.insert(selected, at: 0)
        }
        return languages.isEmpty ? SupportedLanguage.cloudLanguages : languages
    }
}
