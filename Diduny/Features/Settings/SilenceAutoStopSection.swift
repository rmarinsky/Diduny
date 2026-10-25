import SwiftUI

/// "Stop after silence" toggle + seconds slider, shared by dictation and meeting settings.
struct SilenceAutoStopSection: View {
    let footer: LocalizedStringKey
    let range: ClosedRange<Double>
    let step: Double
    @Binding var isEnabled: Bool
    @Binding var seconds: Double

    var body: some View {
        Section {
            Toggle("Stop after silence", isOn: $isEnabled)

            if isEnabled {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Silence")
                        Spacer()
                        Text(Self.durationText(seconds))
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: $seconds, in: range, step: step)
                }
            }
        } header: {
            Text("Stop After Silence")
        } footer: {
            Text(footer)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private static func durationText(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        guard total >= 60 else { return String(localized: "\(total) s") }
        let minutes = total / 60
        let remainder = total % 60
        return remainder == 0
            ? String(localized: "\(minutes) min")
            : String(localized: "\(minutes) min \(remainder) s")
    }
}
