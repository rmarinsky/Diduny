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
    @Published var targetLanguageCode: String
    @Published var detectedLanguageName: String = ""
    @Published var isTranslating: Bool = false
    @Published var errorMessage: String?
    @Published var showCopiedConfirmation: Bool = false

    private var translationTask: Task<Void, Never>?

    deinit {
        translationTask?.cancel()
    }

    init(sourceText: String) {
        self.sourceText = sourceText

        // Detect source language and resolve target
        let detectedCode = Self.detectLanguageCode(for: sourceText)
        detectedLanguageName = Self.languageDisplayName(for: detectedCode)
        targetLanguageCode = Self.resolveTargetLanguage(sourceCode: detectedCode)
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
                    targetLanguage: self.targetLanguageCode
                )
                guard !Task.isCancelled else { return }
                self.translatedText = result
                self.isTranslating = false

                // Auto-copy to clipboard
                ClipboardService.shared.copy(text: result)
                self.showCopiedConfirmation = true

                // Hide confirmation after a delay
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    guard !Task.isCancelled else { return }
                    self.showCopiedConfirmation = false
                }
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
        detectedLanguageName = Self.languageDisplayName(for: detectedCode)
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

    private static func resolveTargetLanguage(sourceCode: String?) -> String {
        let favoriteLanguages = SettingsStorage.shared.favoriteLanguages.filter { !$0.isEmpty }

        switch sourceCode {
        case "uk":
            return favoriteLanguages.first(where: { $0 != "uk" }) ?? "en"
        case "en":
            return favoriteLanguages.first(where: { $0 != "en" }) ?? "uk"
        default:
            return favoriteLanguages.first ?? "uk"
        }
    }

    // MARK: - Translation API

    private static func requestTranslation(sourceText: String, targetLanguage: String) async throws -> String {
        let settings = SettingsStorage.shared
        let proxyBase = settings.proxyBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let translateURL = "\(proxyBase)/api/v1/translations"

        guard var components = URLComponents(string: translateURL) else {
            throw TranslationError.invalidRequest
        }

        components.queryItems = [
            URLQueryItem(name: "q", value: sourceText),
            URLQueryItem(name: "tl", value: targetLanguage),
            URLQueryItem(name: "sl", value: "auto"),
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

}

// MARK: - View

struct TextTranslationView: View {
    @ObservedObject var viewModel: TextTranslationViewModel
    var onClose: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            // Source text
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Source")
                        .font(.headline)

                    if !viewModel.detectedLanguageName.isEmpty {
                        Text(viewModel.detectedLanguageName)
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.secondary.opacity(0.2)))
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

            // Target language + Translate button
            HStack(spacing: 12) {
                Picker("To:", selection: $viewModel.targetLanguageCode) {
                    ForEach(SupportedLanguage.allLanguages) { language in
                        Text(language.name).tag(language.code)
                    }
                }
                .frame(maxWidth: 200)

                Spacer()

                if viewModel.isTranslating {
                    ProgressView()
                        .controlSize(.small)
                }

                Button(action: viewModel.translate) {
                    Text("Translate")
                        .frame(minWidth: 80)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(viewModel.isTranslating || viewModel.sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
                }

                TextEditor(text: .constant(viewModel.translatedText))
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
        .frame(width: 480, height: 400)
        .animation(.easeInOut(duration: 0.2), value: viewModel.showCopiedConfirmation)
    }
}
