import SwiftUI

struct APISettingsView: View {
    @State private var sonioxAPIKey: String = ""
    @State private var showSonioxKey = false
    @State private var isTesting = false
    @State private var testResult: TestResult?

    enum TestResult {
        case success
        case failure(String)
    }

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Soniox API Key")
                        .font(.headline)

                    HStack {
                        Group {
                            if showSonioxKey {
                                TextField("Enter API key", text: $sonioxAPIKey)
                            } else {
                                SecureField("Enter API key", text: $sonioxAPIKey)
                            }
                        }
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: sonioxAPIKey) { _, newValue in
                            saveSonioxKey(newValue)
                        }

                        Button(showSonioxKey ? "Hide" : "Show") {
                            showSonioxKey.toggle()
                        }
                        .buttonStyle(.bordered)

                        Button("Test") {
                            testSonioxConnection()
                        }
                        .buttonStyle(.bordered)
                        .disabled(sonioxAPIKey.isEmpty || isTesting)
                    }

                    Link("Get your key at console.soniox.com",
                         destination: URL(string: "https://console.soniox.com")!)
                        .font(.caption)
                        .foregroundColor(.secondary)

                    if let result = testResult {
                        testResultView(result)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            loadKeys()
        }
    }

    @ViewBuilder
    private func testResultView(_ result: TestResult) -> some View {
        HStack {
            switch result {
            case .success:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                Text("Connection successful")
                    .foregroundColor(.green)
            case let .failure(message):
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.red)
                Text(message)
                    .foregroundColor(.red)
            }
        }
        .font(.caption)
    }

    private func loadKeys() {
        sonioxAPIKey = KeychainManager.shared.getSonioxAPIKey() ?? ""
    }

    private func saveSonioxKey(_ key: String) {
        if key.isEmpty {
            try? KeychainManager.shared.deleteSonioxAPIKey()
        } else {
            try? KeychainManager.shared.setSonioxAPIKey(key)
        }
    }

    func testSonioxConnection() {
        isTesting = true
        testResult = nil

        Task {
            let service = SonioxTranscriptionService()
            service.apiKey = sonioxAPIKey

            do {
                let success = try await service.testConnection()
                await MainActor.run {
                    testResult = success ? .success : .failure("Connection failed")
                    isTesting = false
                }
            } catch {
                await MainActor.run {
                    testResult = .failure(error.localizedDescription)
                    isTesting = false
                }
            }
        }
    }
}

#Preview {
    APISettingsView()
        .frame(width: 450, height: 350)
}
