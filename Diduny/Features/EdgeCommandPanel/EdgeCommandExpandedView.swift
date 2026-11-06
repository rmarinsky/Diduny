import SwiftUI

struct EdgeCommandExpandedView: View {
    let model: EdgeCommandPanelModel
    let liveStore: LiveDictationOverlayStore
    let onAction: (EdgeCommandAction) -> Void
    let onProvider: (TranscriptionProvider) -> Void
    let onSignIn: () -> Void
    let onCopy: () -> Void
    let onStop: () -> Void
    let onDismissLive: () -> Void
    let onMinimizeLive: () -> Void
    let onSelectOutput: (DictationOutput) -> Void
    let onStartMeetingSuggestion: (UUID) -> Void
    let onDismissMeetingSuggestion: (UUID) -> Void
    let onMeetingSuggestionsEnabled: (Bool) -> Void
    let onCollapse: () -> Void
    let onDrag: () -> Void
    let onDragEnd: () -> Void

    var body: some View {
        ZStack {
            if let suggestion = model.meetingSuggestion {
                MeetingSuggestionView(
                    model: model,
                    suggestion: suggestion,
                    onStart: { onStartMeetingSuggestion(suggestion.meeting.id) },
                    onDismiss: { onDismissMeetingSuggestion(suggestion.meeting.id) },
                    onTrackingChanged: onMeetingSuggestionsEnabled,
                    onDrag: onDrag,
                    onDragEnd: onDragEnd
                )
                .transition(.scale(scale: 0.96, anchor: .top).combined(with: .opacity))
            } else if model.isShowingLiveFeedback {
                LivePanelView(
                    store: liveStore,
                    onCopy: onCopy,
                    onStop: onStop,
                    onDismiss: onDismissLive,
                    onMinimize: onMinimizeLive,
                    onSelectOutput: onSelectOutput,
                    onDrag: onDrag,
                    onDragEnd: onDragEnd
                )
                .transition(.scale(scale: 0.96, anchor: .top).combined(with: .opacity))
            } else {
                commandView
                    .transition(.scale(scale: 0.96, anchor: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.38, dampingFraction: 0.86), value: model.isShowingLiveFeedback)
        .animation(.spring(response: 0.38, dampingFraction: 0.86), value: model.meetingSuggestion)
    }

    private var commandView: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 10) {
            header

            providerControl

            if model.showsTranslationControls {
                translationTargetControl(model: model)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 7) {
                ForEach(model.availableActions) { action in
                    EdgeCommandActionButton(
                        action: action,
                        meta: actionMeta(action),
                        onAction: { onAction(action) }
                    )
                }
            }

            Button { onAction(.batch) } label: {
                Label("Batch files & URLs", systemImage: EdgeCommandAction.batch.icon)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 26)
            }
            .buttonStyle(.plain)
            .help("Process multiple files and URLs")
        }
        .padding(14)
        .background(.regularMaterial, in: panelShape)
        .overlay(panelShape.stroke(Color.primary.opacity(0.10), lineWidth: 0.5))
        .animation(.spring(response: 0.32, dampingFraction: 0.9), value: model.provider)
    }

    private var providerControl: some View {
        HStack(spacing: 7) {
            Text("Provider")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)

            HStack(spacing: 2) {
                providerButton(.local, title: "Local", icon: "desktopcomputer")
                providerButton(.cloud, title: "Cloud", icon: model.isSignedIn ? "cloud" : "lock.fill")
            }
            .padding(3)
            .background(Color.black.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            if !model.isSignedIn {
                Button("Sign in", action: onSignIn)
                    .font(.system(size: 10.5, weight: .semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(Color("BrandAccentDeep"))
                    .padding(.horizontal, 7)
                    .frame(height: 26)
                    .background(Color("BrandTintSoft"), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
        }
        .frame(height: 30)
    }

    private func providerButton(
        _ provider: TranscriptionProvider,
        title: String,
        icon: String
    ) -> some View {
        let selected = model.provider == provider
        return Button { onProvider(provider) } label: {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .semibold))
                Text(title)
                    .font(.system(size: 10.5, weight: .semibold))
            }
            .foregroundStyle(selected ? Color.primary : Color.secondary)
            .frame(maxWidth: .infinity, minHeight: 24)
            .padding(.horizontal, 6)
            .background(
                selected ? Color.primary.opacity(0.08) : .clear,
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func translationTargetControl(model: EdgeCommandPanelModel) -> some View {
        @Bindable var model = model
        return HStack(spacing: 8) {
            Text("Translate to")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Picker("Translate to", selection: $model.selectedPairID) {
                ForEach(model.pairs) { pair in
                    Text(languageName(pair.languageB)).tag(pair.id)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
        }
    }

    private var header: some View {
        HStack(spacing: 9) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(LinearGradient(
                    colors: [Color.pink, Color("BrandAccentDeep")],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))
                .frame(width: 28, height: 28)
                .overlay {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .shadow(color: Color("BrandAccentDeep").opacity(0.28), radius: 6, y: 3)

            VStack(alignment: .leading, spacing: 1) {
                Text("Diduny")
                    .font(.system(size: 13, weight: .bold))
                Text("What do you want to capture?")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Button(action: onCollapse) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 26, height: 26)
                    .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
            .buttonStyle(.plain)
            .help("Hide quick actions")
        }
        .contentShape(Rectangle())
        .gesture(dragGesture)
        .help("Drag to attach to another screen edge")
    }

    private var panelShape: RoundedRectangle {
        RoundedRectangle(
            cornerRadius: EdgeCommandPanelPlacement.expandedCornerRadius,
            style: .continuous
        )
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { _ in onDrag() }
            .onEnded { _ in onDragEnd() }
    }

    private func actionMeta(_ action: EdgeCommandAction) -> String {
        switch action {
        case .transcribe: String(localized: "Voice → text")
        case .translate: "Voice → \(targetCode)"
        case .meeting: String(localized: "System + mic")
        case .translateMeeting: "Live → \(targetCode)"
        case .batch: ""
        }
    }

    private var targetCode: String {
        model.selectedPair?.languageB.uppercased() ?? "EN"
    }

    private func languageName(_ code: String) -> String {
        SupportedLanguage.language(for: code)?.name ?? code.uppercased()
    }
}

private struct EdgeCommandActionButton: View {
    let action: EdgeCommandAction
    let meta: String
    let onAction: () -> Void

    @State private var isHovered = false
    @FocusState private var isFocused: Bool

    var body: some View {
        let highlighted = isHovered || isFocused
        Button(action: onAction) {
            VStack(alignment: .leading, spacing: 7) {
                Image(systemName: action.icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color("BrandAccentDeep"))
                    .frame(width: 24, height: 24)
                    .background(Color("BrandTintSoft"), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                Text(action.title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .lineLimit(1)
                Text(meta)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
            }
            .padding(8)
            .frame(maxWidth: .infinity, minHeight: 68, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .buttonStyle(.plain)
        .focused($isFocused)
        .background(
            highlighted ? Color("BrandAccentDeep").opacity(0.11) : Color.primary.opacity(0.045),
            in: RoundedRectangle(cornerRadius: 11, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(highlighted ? Color("BrandTintBorder") : Color.primary.opacity(0.08), lineWidth: 0.5)
        }
        .offset(y: highlighted ? -1 : 0)
        .shadow(color: highlighted ? Color("BrandAccentDeep").opacity(0.14) : .clear, radius: 8, y: 4)
        .animation(.easeOut(duration: 0.15), value: highlighted)
        .onHover { isHovered = $0 }
        .help(action.usesLanguagePair ? String(localized: "Uses the selected translation language") : action.title)
    }
}
