import SwiftUI

// MARK: - Compact Leading (Left side of notch)

struct NotchCompactLeadingView: View {
    @ObservedObject var manager: NotchManager

    var body: some View {
        Group {
            switch manager.state {
            case let .recording(mode):
                RecordingCompactView(mode: mode)

            case let .processing(mode):
                ProcessingCompactView(mode: mode)

            default:
                EmptyView()
            }
        }
    }
}

// MARK: - Compact Trailing (Right side of notch)

struct NotchCompactTrailingView: View {
    @ObservedObject var manager: NotchManager

    var body: some View {
        Group {
            switch manager.state {
            case .recording:
                PulsingDotView()

            case .processing:
                ProgressView()
                    .scaleEffect(0.5)
                    .frame(width: 16, height: 16)

            default:
                EmptyView()
            }
        }
    }
}

// MARK: - Expanded (Below notch)

struct NotchExpandedView: View {
    @ObservedObject var manager: NotchManager

    var body: some View {
        Group {
            switch manager.state {
            case let .success(text):
                SuccessExpandedView(text: text)

            case let .error(message):
                ErrorExpandedView(message: message)

            case let .recording(mode):
                RecordingExpandedView(mode: mode)

            case let .processing(mode):
                ProcessingExpandedView(mode: mode)

            case .idle:
                EmptyView()
            }
        }
        .frame(height: 32)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}

// MARK: - Compact Components

private struct RecordingCompactView: View {
    let mode: RecordingMode

    var body: some View {
        Image(systemName: mode.icon)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(.red)
    }
}

private struct ProcessingCompactView: View {
    let mode: RecordingMode

    var body: some View {
        Image(systemName: mode.icon)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(.orange)
    }
}

private struct PulsingDotView: View {
    @State private var isPulsing = false

    var body: some View {
        Circle()
            .fill(.red)
            .frame(width: 8, height: 8)
            .scaleEffect(isPulsing ? 1.4 : 1.0)
            .opacity(isPulsing ? 0.6 : 1.0)
            .frame(width: 14, height: 14)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
                    isPulsing = true
                }
            }
    }
}

// MARK: - Expanded Components

private struct RecordingExpandedView: View {
    let mode: RecordingMode
    @State private var isPulsing = false

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(.red)
                .frame(width: 10, height: 10)
                .scaleEffect(isPulsing ? 1.3 : 1.0)
                .opacity(isPulsing ? 0.7 : 1.0)

            Image(systemName: mode.icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.red)

            Text(mode.label)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                isPulsing = true
            }
        }
    }
}

private struct ProcessingExpandedView: View {
    let mode: RecordingMode

    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
                .scaleEffect(0.7)
                .frame(width: 16, height: 16)

            Text(mode.processingLabel)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.orange)
        }
    }
}

private struct SuccessExpandedView: View {
    let text: String

    private var preview: String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count > 35 {
            return String(trimmed.prefix(35)) + "..."
        }
        return trimmed
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.green)

            Text(preview)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
    }
}

private struct ErrorExpandedView: View {
    let message: String

    private var shortMessage: String {
        if message.count > 40 {
            return String(message.prefix(40)) + "..."
        }
        return message
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.red)

            Text(shortMessage)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.red)
                .lineLimit(1)
        }
    }
}
