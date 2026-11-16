import PapugaKit
import SwiftUI

extension TypingRecoveryHint {
    var title: String {
        switch self {
        case .bringBackProposal: String(localized: "Bring back the hint")
        case .applyAgain: String(localized: "Apply again")
        }
    }
}

extension TypingProposalHint {
    var title: String {
        switch kind {
        case .replacement: String(localized: "Possible replacement")
        case .correction: String(localized: "Possible fix")
        }
    }

    var neverTitle: String {
        switch kind {
        case .replacement: String(localized: "Never replace “\(original)”")
        case .correction: String(localized: "Never fix “\(original)”")
        }
    }

    var replaceTooltip: String {
        createsRuleOnAcceptance
            ? String(localized: "Replace and create a rule. Enter")
            : String(localized: "Fix this case. Enter")
    }

    var receiptLabel: String {
        String(localized: "Possible replacement of \(original) with \(candidate)")
    }
}

extension TypingHintContent {
    /// What VoiceOver says when the hint appears.
    var announcement: String {
        switch self {
        case .undo, .recovery: title
        case let .chip(original, candidate, _, _, _): "\(title): \(original) → \(candidate)"
        case let .proposal(hint, _, _, _): hint.receiptLabel
        }
    }
}

/// One hint. The panel gives it its size; the open motion is M6 (scale from `popScale`), and the
/// panel fades the window. Reduce Motion keeps only the fade.
struct TypingHintView: View {
    let content: TypingHintContent
    let motion: MotionPreference
    @State private var isOpen = false

    var body: some View {
        Group {
            switch content {
            case let .undo(onClick):
                HintPill(
                    symbol: onClick == nil ? "checkmark" : "arrow.uturn.backward",
                    title: content.title,
                    identifier: "typingHint.undo.action",
                    onClick: onClick,
                    landsLogo: true
                )
            case let .recovery(hint, onClick):
                HintPill(
                    symbol: "arrow.uturn.backward",
                    title: hint.title,
                    identifier: "typingHint.recovery.action",
                    onClick: onClick
                )
            case let .chip(original, candidate, timeToLive, onApply, onDismiss):
                DeferredChip(
                    original: original, candidate: candidate, timeToLive: timeToLive,
                    onApply: onApply, onDismiss: onDismiss
                )
            case let .proposal(hint, onReplace, onDismiss, onNeverReplace):
                ProposalHint(hint: hint, onReplace: onReplace, onDismiss: onDismiss, onNeverReplace: onNeverReplace)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .scaleEffect(isOpen || motion.reduceMotion ? 1 : DS.Motion.popScale)
        .onAppear {
            guard !motion.reduceMotion else { return }
            withAnimation(DS.Motion.easeOut(DS.Motion.m6PopupOpen.duration)) { isOpen = true }
        }
    }
}

/// The small toast shape the app already uses (in-place translation): material, 16 radius, tint border.
private struct HintPillSurface: ViewModifier {
    var isHighlighted = false
    /// False while the fix hint's logo lands on its own, before the pill appears around it.
    var isShown = true

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
    }

    func body(content: Content) -> some View {
        content
            .frame(height: 32)
            .background { shape.fill(.regularMaterial).opacity(isShown ? 1 : 0) }
            .overlay(shape.strokeBorder(isHighlighted ? DS.Palette.accentText : DS.Palette.tintBorder, lineWidth: isHighlighted ? 1 : 0.5).opacity(isShown ? 1 : 0))
            .clipShape(shape)
            .contentShape(shape)
    }
}

/// The undo hint and the recovery hint: a symbol and one line. With `onClick` the whole pill is a button.
private struct HintPill: View {
    let symbol: String
    let title: String
    let identifier: String
    let onClick: (() -> Void)?
    /// The fix hint: the Diduny logo first lands as after a translation or a paste (pop, ring, check,
    /// sparks) and turns once, then the pill and its title appear around it and the logo stays.
    var landsLogo = false
    @State private var isHovered = false
    @State private var isRevealed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if let onClick {
            Button(action: onClick) { label }
                .buttonStyle(.plain)
                .onHover { isHovered = $0 }
                .accessibilityLabel(Text(verbatim: title))
                .accessibilityIdentifier(identifier)
        } else {
            label
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: title))
        }
    }

    private var label: some View {
        HStack(spacing: 6) {
            if landsLogo {
                LogoBadge(phase: .done, discSize: 24, pulsesOnAppear: true, spinsOnAppear: true)
            } else {
                Image(systemName: symbol)
                    .font(.system(size: DS.Size.symbolSmall, weight: .semibold))
                    .foregroundStyle(DS.Palette.secondary)
            }
            Text(verbatim: title)
                .font(DS.Font.calloutStrong)
                .foregroundStyle(DS.Palette.text)
                .lineLimit(1)
                .opacity(isShown ? 1 : 0)
        }
        .padding(.horizontal, landsLogo ? DS.Space.xs : DS.Space.md)
        .padding(.trailing, landsLogo ? DS.Space.md - DS.Space.xs : 0)
        .modifier(HintPillSurface(isHighlighted: isHovered, isShown: isShown))
        .task {
            guard landsLogo, !isRevealed else { return }
            if !reduceMotion { try? await Task.sleep(for: .seconds(Self.landing)) }
            withAnimation(DS.Motion.easeOut(0.2)) { isRevealed = true }
        }
    }

    /// The logo's turn takes 0.6 s; the title follows once it settles.
    static let landing: TimeInterval = 0.5

    private var isShown: Bool { !landsLogo || isRevealed }
}

/// A fix the user typed past. It never listens to the keyboard: a click applies it, the cross
/// closes it, and the bar along the bottom shows the time it has left.
private struct DeferredChip: View {
    let original: String
    let candidate: String
    let timeToLive: TimeInterval
    let onApply: () -> Void
    let onDismiss: () -> Void
    @State private var remaining: CGFloat = 1
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: DS.Space.xs) {
            Button(action: onApply) {
                HStack(spacing: 6) {
                    Text(verbatim: original)
                        .font(DS.Font.callout)
                        .foregroundStyle(DS.Palette.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Image(systemName: "arrow.right")
                        .font(.system(size: DS.Size.symbolChevron, weight: .semibold))
                        .foregroundStyle(DS.Palette.secondary)
                    Text(verbatim: candidate)
                        .font(DS.Font.calloutStrong)
                        .foregroundStyle(DS.Palette.accentText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Apply the deferred fix"))
            .accessibilityValue(Text(verbatim: "\(original) → \(candidate)"))
            .accessibilityIdentifier("typingHint.chip.apply")

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: DS.Size.symbolChevron, weight: .semibold))
                    .foregroundStyle(DS.Palette.secondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Close the hint"))
            .accessibilityIdentifier("typingHint.chip.dismiss")
        }
        .padding(.leading, DS.Space.md)
        .padding(.trailing, 6)
        .overlay(alignment: .bottom) {
            // A transform, not an animated width: draining never invalidates layout.
            Rectangle()
                .fill(DS.Palette.accentFill)
                .frame(height: 2)
                .scaleEffect(x: remaining, y: 1, anchor: .leading)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .modifier(HintPillSurface(isHighlighted: isHovered))
        .onHover { isHovered = $0 }
        .onAppear {
            // Linear in every motion setting: the bar is a countdown, like a progress bar (M16).
            withAnimation(.linear(duration: timeToLive)) { remaining = 0 }
        }
    }
}

/// The proposal for an unclear case, in the popup shell's look: title and Esc, `source → target`,
/// "never" and Enter.
private struct ProposalHint: View {
    let hint: TypingProposalHint
    let onReplace: () -> Void
    let onDismiss: () -> Void
    let onNeverReplace: () -> Void

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: DS.Radius.popup, style: .continuous)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Panel.blockGap) {
            HStack(spacing: DS.Space.sm) {
                Text(verbatim: hint.title)
                    .font(DS.Font.headline)
                    .foregroundStyle(DS.Palette.text)
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: DS.Space.sm)
                Button(action: onDismiss) {
                    HStack(spacing: DS.Space.xs) {
                        Image(systemName: "xmark")
                            .font(.system(size: DS.Size.symbolChevron, weight: .semibold))
                        Text(verbatim: "Esc")
                            .font(DS.Font.keycap)
                    }
                    .foregroundStyle(DS.Palette.secondary)
                    .padding(.horizontal, 6)
                    .frame(height: 22)
                    .background(DS.Palette.chip, in: RoundedRectangle(cornerRadius: DS.Radius.iconButton, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressScaleButtonStyle())
                .help(Text("Close the hint. You can bring it back within 10 seconds. Esc"))
                .accessibilityLabel(Text("Close the hint"))
                .accessibilityIdentifier("typingHint.proposal.dismiss")
            }

            HStack(spacing: DS.Space.sm) {
                pill(hint.original, foreground: DS.Palette.text, background: DS.Palette.box)
                    .accessibilityIdentifier("typingHint.proposal.source")
                Image(systemName: "arrow.right")
                    .font(.system(size: DS.Size.symbolIconButton, weight: .semibold))
                    .foregroundStyle(DS.Palette.secondary)
                    .accessibilityHidden(true)
                pill(hint.candidate, foreground: DS.Palette.accentText, background: DS.Palette.tint)
                    .accessibilityIdentifier("typingHint.proposal.target")
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: hint.receiptLabel))

            HStack(spacing: DS.Space.md) {
                Button(action: onNeverReplace) {
                    Text(verbatim: hint.neverTitle)
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Palette.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(Text("Never suggest this replacement again"))
                .accessibilityIdentifier("typingHint.proposal.never")
                Spacer(minLength: 0)
                Button(action: onReplace) {
                    HStack(spacing: DS.Space.xs) {
                        Image(systemName: "return")
                            .font(.system(size: DS.Size.symbolChevron, weight: .semibold))
                        Text(verbatim: "Enter")
                            .font(DS.Font.keycap)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, DS.Space.sm)
                    .frame(height: 24)
                    .background(DS.Palette.accentFill, in: RoundedRectangle(cornerRadius: DS.Radius.panelButton, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressScaleButtonStyle())
                .layoutPriority(1)
                .help(Text(verbatim: hint.replaceTooltip))
                .accessibilityLabel(Text("Replace"))
                .accessibilityIdentifier("typingHint.proposal.replace")
            }
        }
        .padding(DS.Panel.padding + DS.Panel.borderWidth)
        .background(DS.Palette.panel, in: shape)
        .overlay(shape.strokeBorder(DS.Palette.line, lineWidth: DS.Panel.borderWidth))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: hint.title))
    }

    private func pill(_ text: String, foreground: Color, background: Color) -> some View {
        Text(verbatim: text)
            .font(.system(size: 12, weight: .semibold, design: .monospaced))
            .foregroundStyle(foreground)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, DS.Space.sm)
            .frame(height: 24)
            .background(background, in: RoundedRectangle(cornerRadius: DS.Radius.searchField, style: .continuous))
    }
}
