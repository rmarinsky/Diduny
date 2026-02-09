import SwiftUI

// MARK: - Button Styles

struct ScaleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

struct OnboardingPrimaryButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 200, height: 44)
                .background(Color.accentColor)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .focusable(false)
    }
}

struct OnboardingSecondaryButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.secondary)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Progress Dots

struct ProgressDots: View {
    let total: Int
    let current: Int

    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<total, id: \.self) { index in
                Circle()
                    .fill(index <= current ? Color.accentColor : Color.gray.opacity(0.3))
                    .frame(width: 8, height: 8)
                    .scaleEffect(index == current ? 1.2 : 1.0)
                    .animation(.spring(response: 0.3, dampingFraction: 0.7), value: current)
            }
        }
    }
}

// MARK: - Key Cap View

struct KeyCapView: View {
    let symbol: String
    let isPressed: Bool

    var body: some View {
        Text(symbol)
            .font(.system(size: 16, weight: .semibold, design: .rounded))
            .foregroundColor(.primary)
            .frame(minWidth: 32, minHeight: 32)
            .padding(.horizontal, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .shadow(color: .black.opacity(0.15), radius: 1, x: 0, y: 1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.gray.opacity(0.3), lineWidth: 1)
            )
            .scaleEffect(isPressed ? 0.95 : 1.0)
            .animation(.spring(response: 0.2, dampingFraction: 0.6), value: isPressed)
    }
}

// MARK: - Key Option Button

struct KeyOptionButton: View {
    let key: PushToTalkKey
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Text(key.symbol)
                    .font(.system(size: 20, weight: .semibold))

                Text(key.displayName.replacingOccurrences(of: "Right ", with: ""))
                    .font(.caption2)
            }
            .frame(width: 70, height: 60)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected ? Color.accentColor.opacity(0.15) : Color.gray.opacity(0.1))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
        .foregroundColor(isSelected ? .accentColor : .primary)
    }
}

// MARK: - Background View

struct OnboardingBackgroundView: View {
    var body: some View {
        ZStack {
            // Base color
            Color(nsColor: .windowBackgroundColor)

            // Subtle gradient overlay
            LinearGradient(
                colors: [
                    Color.accentColor.opacity(0.03),
                    Color.clear,
                    Color.accentColor.opacity(0.02)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        .ignoresSafeArea()
    }
}

#Preview("Components") {
    VStack(spacing: 30) {
        ProgressDots(total: 6, current: 2)

        HStack(spacing: 8) {
            KeyCapView(symbol: "⇧", isPressed: false)
            KeyCapView(symbol: "⇧", isPressed: true)
        }

        HStack(spacing: 12) {
            KeyOptionButton(key: .rightShift, isSelected: true) {}
            KeyOptionButton(key: .rightCommand, isSelected: false) {}
        }

        OnboardingPrimaryButton(title: "Continue") {}
        OnboardingSecondaryButton(title: "Skip for now") {}
    }
    .padding(40)
    .frame(width: 500, height: 400)
    .background(OnboardingBackgroundView())
}
