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
        .animation(.easeInOut(duration: 0.2), value: manager.state)
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
        .animation(.easeInOut(duration: 0.2), value: manager.state)
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
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))

            case let .error(message):
                ErrorExpandedView(message: message)
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))

            case let .info(message):
                InfoExpandedView(message: message)
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))

            case let .recording(mode):
                RecordingExpandedView(mode: mode)
                    .transition(.opacity)

            case let .processing(mode):
                ProcessingExpandedView(mode: mode)
                    .transition(.opacity)

            case .idle:
                EmptyView()
            }
        }
        .frame(height: 20)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .animation(.easeInOut(duration: 0.35), value: manager.state)
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
        HStack(spacing: 8) {
            Circle()
                .fill(.red)
                .frame(width: 8, height: 8)
                .scaleEffect(isPulsing ? 1.3 : 1.0)
                .opacity(isPulsing ? 0.7 : 1.0)

            Image(systemName: mode.icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.red)

            Text(mode.label)
                .font(.system(size: 12, weight: .medium))
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
        HStack(spacing: 8) {
            ProgressView()
                .scaleEffect(0.6)
                .frame(width: 14, height: 14)

            Text(mode.processingLabel)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.orange)
        }
    }
}

private struct SuccessExpandedView: View {
    let text: String
    @State private var appeared = false

    private var preview: String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count > 35 {
            return String(trimmed.prefix(35)) + "..."
        }
        return trimmed
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.green)
                .scaleEffect(appeared ? 1.0 : 0.3)
                .opacity(appeared ? 1.0 : 0.0)

            Text(preview)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .opacity(appeared ? 1.0 : 0.0)
                .offset(x: appeared ? 0 : -5)

            Spacer()

            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 18, height: 18)
                .scaleEffect(appeared ? 1.0 : 0.5)
                .opacity(appeared ? 1.0 : 0.0)
        }
        .onAppear {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) {
                appeared = true
            }
        }
    }
}

private struct ErrorExpandedView: View {
    let message: String
    @State private var appeared = false

    private var shortMessage: String {
        if message.count > 40 {
            return String(message.prefix(40)) + "..."
        }
        return message
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.red)
                .scaleEffect(appeared ? 1.0 : 0.3)
                .opacity(appeared ? 1.0 : 0.0)

            Text(shortMessage)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.red)
                .lineLimit(1)
                .opacity(appeared ? 1.0 : 0.0)
                .offset(x: appeared ? 0 : -5)

            Spacer()

            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 18, height: 18)
                .scaleEffect(appeared ? 1.0 : 0.5)
                .opacity(appeared ? 0.6 : 0.0)
        }
        .onAppear {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) {
                appeared = true
            }
        }
    }
}

private struct InfoExpandedView: View {
    let message: String
    @State private var appeared = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "escape")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.orange)
                .scaleEffect(appeared ? 1.0 : 0.3)
                .opacity(appeared ? 1.0 : 0.0)

            Text(message)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .opacity(appeared ? 1.0 : 0.0)
                .offset(x: appeared ? 0 : -5)

            Spacer()

            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 18, height: 18)
                .scaleEffect(appeared ? 1.0 : 0.5)
                .opacity(appeared ? 0.8 : 0.0)
        }
        .onAppear {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) {
                appeared = true
            }
        }
    }
}
