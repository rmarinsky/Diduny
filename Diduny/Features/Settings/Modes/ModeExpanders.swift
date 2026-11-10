import SwiftUI

/// The options under an open mode row (05 2.1.2): settings rows indented 160, last row without hairline.
struct ModeExpander: View {
    let job: STTJob
    @Bindable var model: ModesViewModel

    private var id: String { "modes.\(job.rawValue)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch job {
            case .dictation, .dictationTranslation:
                pushToTalkRows
                silenceRow(last: true)
            case .meeting:
                meetingRows
                silenceRow(last: true)
            case .meetingTranslation:
                SettingsLineRow(title: "Show original text", caption: "Only with an engine that returns both texts.", kind: .toggle) {
                    SettingsSwitch(title: "Show original text", isOn: $model.meetingTranslationShowOriginal)
                        .accessibilityIdentifier("\(id).showOriginal")
                }
                silenceRow(last: true)
            case .file:
                EmptyView()
            }
        }
        .padding(.leading, ModesGrid.detailIndent)
        .padding(.top, DS.Space.sm)
        .padding(.bottom, ModesGrid.rowPadding)
    }

    // MARK: Dictation and Translation

    @ViewBuilder private var pushToTalkRows: some View {
        let ptt = model.pushToTalk(for: job)
        SettingsLineRow(title: "Key to hold or tap", kind: .popUp) {
            Picker("Key to hold or tap", selection: Binding(
                get: { ptt.key },
                set: { key in model.updatePushToTalk(for: job) { $0.key = key } }
            )) {
                ForEach(PushToTalkKey.allCases) { Text(verbatim: $0.displayName).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            .accessibilityIdentifier("\(id).pttKey")
        }
        if model.blocksInplaceTranslation(), ptt.key != .none {
            WarningLine(
                message: String(localized: "Unavailable while modifier-key shortcuts use both Option keys or both Command keys."),
                id: "\(id).pttConflict"
            )
            .padding(.bottom, DS.Space.sm)
        }
        SettingsLineRow(title: "Tap to start and stop", kind: .segmented) {
            Picker("Tap to start and stop", selection: Binding(
                get: { model.tapSelection(for: job) },
                set: { model.setTapSelection($0, for: job) }
            )) {
                Text("Off").tag(0)
                Text(verbatim: "2×").tag(2)
                Text(verbatim: "3×").tag(3)
            }
            .pickerStyle(.segmented)
            .controlSize(.small)
            .tint(DS.Palette.accentFill)
            .labelsHidden()
            .fixedSize()
            .accessibilityIdentifier("\(id).tapCount")
        }
        SettingsLineRow(title: "Hold to record", kind: .toggle) {
            SettingsSwitch(title: "Hold to record", isOn: Binding(
                get: { ptt.holdEnabled },
                set: { on in model.updatePushToTalk(for: job) { $0.holdEnabled = on } }
            ))
            .accessibilityIdentifier("\(id).hold")
        }
        SettingsLineRow(title: "Hold for", caption: "How long you hold the key before recording starts.") {
            Slider(value: Binding(
                get: { ptt.holdDelaySeconds },
                set: { seconds in model.updatePushToTalk(for: job) { $0.holdDelaySeconds = seconds } }
            ), in: 0.5 ... 2.0, step: 0.1)
            .controlSize(.small)
            .frame(width: 140)
            .accessibilityIdentifier("\(id).holdFor")
            Text(verbatim: model.holdForLabel(ptt.holdDelaySeconds))
                .font(DS.Font.callout.monospacedDigit())
                .foregroundStyle(DS.Palette.secondary)
                .frame(width: 36, alignment: .trailing)
                .accessibilityIdentifier("\(id).holdFor.value")
        }
        // Proposal 05 2.1.2: the slider follows the hold switch, as today.
        .disabled(!ptt.holdEnabled)
    }

    // MARK: Meeting

    @ViewBuilder private var meetingRows: some View {
        segmentRow(.thisMac, title: "Local engine", caption: "Live text made on this Mac.", suffix: "localLive")
        segmentRow(.cloud, title: "Engine in Cloud", caption: "Live text from the cloud.", suffix: "cloudLive")
        segmentRow(
            .recordOnly,
            title: "Transcript for Record only",
            caption: "Made after Stop. Engines on this Mac are recommended; speaker labels come with Diduny Cloud.",
            suffix: "recordOnly"
        )
        SettingsLineRow(title: "Calendar meetings", caption: "A meeting started from the calendar uses \"Starts in\" and these engines.") {
            Text("Start the same way")
                .font(DS.Font.callout)
                .foregroundStyle(DS.Palette.secondary)
                .accessibilityIdentifier("\(id).calendar")
        }
        SettingsLineRow(title: "Suggest recording when a meeting starts", kind: .toggle) {
            SettingsSwitch(title: "Suggest recording when a meeting starts", isOn: $model.meetingSuggestionsEnabled)
                .accessibilityIdentifier("\(id).suggest")
        }
    }

    private func segmentRow(_ segment: MeetingSegment, title: LocalizedStringKey, caption: LocalizedStringKey, suffix: String) -> some View {
        let value = model.engineName(model.meetingEngine(for: segment))
        let fieldID = "\(id).engine.\(suffix)"
        return SettingsLineRow(title: title, caption: caption) {
            Group {
                if model.isStatic(job: .meeting, segment: segment) {
                    PickerField(staticLabel: nil, value: value, identifier: fieldID)
                } else {
                    PickerField(label: nil, value: value, identifier: fieldID) {
                        model.engineMenu(job: .meeting, segment: segment)
                    } onPick: { model.pickEngine($0, job: .meeting, segment: segment) }
                }
            }
            .frame(width: ModesGrid.detailFieldWidth)
        }
    }

    // MARK: Stop after silence

    private func silenceRow(last: Bool) -> some View {
        let silence = model.silence(for: job)
        return SettingsLineRow(title: "Stop after silence", kind: .popUp, showsHairline: !last) {
            SettingsSwitch(title: "Stop after silence", isOn: Binding(
                get: { silence.enabled },
                set: { model.setSilence(ModeSilence(enabled: $0, seconds: silence.seconds), for: job) }
            ))
            .accessibilityIdentifier("\(id).silence")
            Picker("Stop after silence", selection: Binding(
                get: { silence.seconds },
                set: { model.setSilence(ModeSilence(enabled: silence.enabled, seconds: $0), for: job) }
            )) {
                ForEach(model.silenceOptions(for: job), id: \.self) { seconds in
                    Text(verbatim: "\(Int(seconds)) s").tag(seconds)
                }
            }
            .labelsHidden()
            .fixedSize()
            .disabled(!silence.enabled)
            .accessibilityIdentifier("\(id).silenceSeconds")
        }
    }
}
