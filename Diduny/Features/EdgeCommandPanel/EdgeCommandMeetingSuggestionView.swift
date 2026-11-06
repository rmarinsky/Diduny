import SwiftUI

struct MeetingSuggestionView: View {
    let model: EdgeCommandPanelModel
    let suggestion: MeetingSuggestion
    let onStart: () -> Void
    let onDismiss: () -> Void
    let onTrackingChanged: (Bool) -> Void
    let onDrag: () -> Void
    let onDragEnd: () -> Void

    var body: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "record.circle")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Color("BrandAccentDeep"))
                    .frame(
                        width: EdgeCommandPanelPlacement.meetingSuggestionControlHitTargetHeight,
                        height: EdgeCommandPanelPlacement.meetingSuggestionControlHitTargetHeight
                    )
                    .background(Color("BrandTintSoft"), in: RoundedRectangle(cornerRadius: 11))
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 5) {
                    Text("Looks like a meeting started")
                        .font(.system(size: 15, weight: .semibold))
                    Text(message)
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)

                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(
                            width: EdgeCommandPanelPlacement.meetingSuggestionControlHitTargetHeight,
                            height: EdgeCommandPanelPlacement.meetingSuggestionControlHitTargetHeight
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close meeting recording suggestion")
            }
            .contentShape(Rectangle())
            .gesture(dragGesture)

            Picker(
                "Meeting transcription provider",
                selection: Binding(
                    get: { model.meetingSuggestion?.selectedProvider ?? suggestion.selectedProvider },
                    set: { model.selectMeetingSuggestionProvider($0) }
                )
            ) {
                Text("Cloud").tag(TranscriptionProvider.cloud)
                Text("Local").tag(TranscriptionProvider.local)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .disabled(!suggestion.isCloudAvailable)
            .frame(minHeight: EdgeCommandPanelPlacement.meetingSuggestionControlHitTargetHeight)
            .accessibilityLabel("Meeting transcription provider")
            .accessibilityHint(
                suggestion.isCloudAvailable
                    ? "Choose Cloud or Local transcription"
                    : "Cloud is unavailable. Local transcription will be used."
            )

            Label(suggestion.processingMode.label, systemImage: suggestion.processingMode.icon)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .frame(minHeight: 32)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))

            Toggle(
                "Continue tracking meetings and suggesting recordings",
                isOn: $model.meetingSuggestionsEnabled
            )
            .toggleStyle(.checkbox)
            .font(.system(size: 11.5))
            .frame(
                minHeight: EdgeCommandPanelPlacement.meetingSuggestionControlHitTargetHeight,
                alignment: .leading
            )
            .onChange(of: model.meetingSuggestionsEnabled) { _, enabled in
                onTrackingChanged(enabled)
            }
            .accessibilityLabel("Continue tracking meetings and suggesting recordings")

            HStack(spacing: 8) {
                Button(action: onDismiss) {
                    Text("Not now")
                        .frame(
                            maxWidth: .infinity,
                            minHeight: EdgeCommandPanelPlacement.meetingSuggestionControlHitTargetHeight
                        )
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel("Not now")

                Button(action: onStart) {
                    Text("Start recording")
                        .frame(
                            maxWidth: .infinity,
                            minHeight: EdgeCommandPanelPlacement.meetingSuggestionControlHitTargetHeight
                        )
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .accessibilityLabel("Start recording and transcription")
            }
        }
        .padding(16)
        .background(.regularMaterial, in: panelShape)
        .overlay(panelShape.stroke(Color.primary.opacity(0.10), lineWidth: 0.5))
        .onExitCommand(perform: onDismiss)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Meeting recording suggestion")
    }

    private var message: String {
        String(
            format: String(
                localized: "Start recording and transcription in %@ so you can return to the materials after the meeting?"
            ),
            suggestion.meeting.client.displayName
        )
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
}
