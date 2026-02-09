import SwiftUI

struct AboutSettingsView: View {
    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
    }

    var body: some View {
        Form {
            Section {
                VStack(spacing: 16) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 96, height: 96)

                    Text("Diduny")
                        .font(.title.bold())

                    Text("Version \(appVersion) (\(buildNumber))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Text("Voice dictation for macOS")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }

            Section("Links") {
                LinkRow(
                    title: "Website",
                    subtitle: "rmarinsky.com.ua",
                    systemImage: "globe",
                    url: "https://rmarinsky.com.ua"
                )

                LinkRow(
                    title: "GitHub",
                    subtitle: "github.com/nickolay-rmrsky",
                    systemImage: "chevron.left.forwardslash.chevron.right",
                    url: "https://github.com/nickolay-rmrsky"
                )

                LinkRow(
                    title: "LinkedIn",
                    subtitle: "linkedin.com/in/rmarinskyi",
                    systemImage: "person.crop.rectangle",
                    url: "https://linkedin.com/in/rmarinskyi"
                )
            }

            Section {
                Link(destination: URL(string: "https://base.monobank.ua/3yGFDUvCLJuNhm#subscriptions")!) {
                    HStack {
                        Spacer()
                        Label("Support Diduny", systemImage: "heart.fill")
                            .font(.headline)
                        Spacer()
                    }
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.pink)
            }

            Section {
                VStack(spacing: 8) {
                    Text("Made in Ukraine")
                        .font(.headline)

                    Text("Diduny is proudly built in Ukraine. The name comes from Ukrainian word \"diduny\" — a symbol of heritage and roots.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
            }

            Section {
                Text("\u{00A9} 2024–2026 Roman Marinsky")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
            }
        }
        .formStyle(.grouped)
    }
}

private struct LinkRow: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let url: String

    var body: some View {
        Link(destination: URL(string: url)!) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .frame(width: 20)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Image(systemName: "arrow.up.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

#Preview {
    AboutSettingsView()
        .frame(width: 600, height: 650)
}
