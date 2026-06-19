import AppKit
import KeyboardShortcuts
import SwiftUI

struct ShortcutsSettingsView: View {
    @State private var pushToTalkKey = SettingsStorage.shared.pushToTalkKey
    @State private var pushToTalkHoldEnabled = SettingsStorage.shared.pushToTalkHoldEnabled
    @State private var pushToTalkToggleEnabled = SettingsStorage.shared.pushToTalkToggleEnabled
    @State private var pushToTalkTapCount = SettingsStorage.shared.pushToTalkToggleTapCount
    @State private var pushToTalkHoldStartDelay = SettingsStorage.shared.pushToTalkHoldStartDelaySeconds
    @State private var translationPushToTalkKey = SettingsStorage.shared.translationPushToTalkKey
    @State private var translationPushToTalkHoldEnabled = SettingsStorage.shared.translationPushToTalkHoldEnabled
    @State private var translationPushToTalkToggleEnabled = SettingsStorage.shared.translationPushToTalkToggleEnabled
    @State private var translationPushToTalkTapCount = SettingsStorage.shared.translationPushToTalkToggleTapCount
    @State private var translationPushToTalkHoldStartDelay =
        SettingsStorage.shared.translationPushToTalkHoldStartDelaySeconds
    @State private var recordingHotkeyPressCount = SettingsStorage.shared.recordingHotkeyPressCount
    @State private var translationHotkeyPressCount = SettingsStorage.shared.translationHotkeyPressCount
    @State private var meetingHotkeyPressCount = SettingsStorage.shared.meetingHotkeyPressCount
    @State private var meetingTranslationHotkeyPressCount = SettingsStorage.shared.meetingTranslationHotkeyPressCount
    @State private var translateSelectedTextHotkeyPressCount = SettingsStorage.shared.translateSelectedTextHotkeyPressCount
    @State private var escapeCancelEnabled = SettingsStorage.shared.escapeCancelEnabled
    @State private var escapeCancelPressCount = SettingsStorage.shared.escapeCancelPressCount
    @State private var escapeCancelSaveAudio = SettingsStorage.shared.escapeCancelSaveAudio
    @State private var shortcutDisplayRefresh = 0

    private let hotkeyPressCountOptions = [1, 2, 3]
    private let toggleTapCountOptions = [2, 3]
    private let escapePressCountOptions = [2, 3]

    var body: some View {
        ZStack(alignment: .topLeading) {
            ShortcutStyle.windowBackground
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                header

                Spacer()
                    .frame(height: 10)

                sectionTitle("ACTION HOTKEYS")

                Spacer()
                    .frame(height: 10)

                actionHotkeysCard

                Spacer()
                    .frame(height: 10)

                sectionTitle("MODIFIER KEY RECORDING")

                Spacer()
                    .frame(height: 10)

                modifierKeyRecordingCard

                Spacer()
                    .frame(height: 10)

                sectionTitle("CANCEL RECORDING")

                Spacer()
                    .frame(height: 10)

                cancelRecordingCard
            }
            .frame(width: ShortcutLayout.contentWidth, alignment: .topLeading)
            .padding(.leading, ShortcutLayout.contentLeading)
            .padding(.top, ShortcutLayout.contentTop)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Text("Shortcuts")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(ShortcutStyle.primaryText)

            Spacer()

            Text("Editable")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(ShortcutStyle.accent)
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(ShortcutStyle.accentSoft, in: Capsule())
                .overlay {
                    Capsule()
                        .stroke(ShortcutStyle.accentBorder, lineWidth: 1)
                }
        }
        .frame(width: ShortcutLayout.contentWidth, height: 30)
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(ShortcutStyle.tertiaryText)
            .frame(width: ShortcutLayout.contentWidth, height: 13, alignment: .leading)
    }

    // MARK: - Action Hotkeys

    private var actionHotkeysCard: some View {
        settingsCard {
            actionHeader
            divider

            actionHotkeyRow(
                title: "Dictation",
                shortcut: .toggleRecording,
                pressCount: $recordingHotkeyPressCount,
                store: { SettingsStorage.shared.recordingHotkeyPressCount = $0 }
            )
            divider

            actionHotkeyRow(
                title: "Translation",
                shortcut: .toggleTranslation,
                pressCount: $translationHotkeyPressCount,
                store: { SettingsStorage.shared.translationHotkeyPressCount = $0 }
            )
            divider

            actionHotkeyRow(
                title: "Translate Selected Text",
                shortcut: .translateSelectedText,
                pressCount: $translateSelectedTextHotkeyPressCount,
                store: { SettingsStorage.shared.translateSelectedTextHotkeyPressCount = $0 }
            )
            divider

            actionHotkeyRow(
                title: "Meeting",
                shortcut: .toggleMeetingRecording,
                pressCount: $meetingHotkeyPressCount,
                store: { SettingsStorage.shared.meetingHotkeyPressCount = $0 }
            )
            divider

            actionHotkeyRow(
                title: "Meeting Translation",
                shortcut: .toggleMeetingTranslation,
                pressCount: $meetingTranslationHotkeyPressCount,
                store: { SettingsStorage.shared.meetingTranslationHotkeyPressCount = $0 }
            )
        }
    }

    private var actionHeader: some View {
        HStack(spacing: 0) {
            headerCell("Action", width: ShortcutLayout.actionTitleColumn)
            headerCell("Shortcut", width: ShortcutLayout.actionShortcutColumn)
            headerCell("Trigger after", width: ShortcutLayout.actionTriggerColumn)
            Spacer(minLength: 0)
        }
        .frame(height: 30)
    }

    private func actionHotkeyRow(
        title: String,
        shortcut: KeyboardShortcuts.Name,
        pressCount: Binding<Int>,
        store: @escaping (Int) -> Void
    ) -> some View {
        HStack(spacing: 0) {
            rowTitle(title, width: ShortcutLayout.actionTitleColumn)

            shortcutRecorderField(for: shortcut)
                .frame(width: ShortcutLayout.actionShortcutColumn, alignment: .leading)

            countSegmentedPicker(
                selection: pressCount,
                options: hotkeyPressCountOptions,
                width: ShortcutLayout.actionTriggerWidth
            )
            .frame(width: ShortcutLayout.actionTriggerColumn, alignment: .leading)

            Spacer(minLength: 0)
        }
        .frame(height: 48)
        .onChange(of: pressCount.wrappedValue) { _, newValue in
            store(newValue)
        }
    }

    private func shortcutRecorderField(for shortcut: KeyboardShortcuts.Name) -> some View {
        let tokens = shortcutTokens(for: shortcut, refresh: shortcutDisplayRefresh)

        return ZStack(alignment: .leading) {
            HStack(spacing: 6) {
                if tokens.isEmpty {
                    Text("record shortcut")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(ShortcutStyle.secondaryText)
                } else {
                    ForEach(Array(tokens.enumerated()), id: \.offset) { _, token in
                        keycap(token)
                    }
                }

                Spacer(minLength: 8)

                Text("edit")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(ShortcutStyle.accent)
            }
            .padding(.horizontal, 10)
            .frame(width: ShortcutLayout.shortcutInputWidth, height: 32)
            .background(ShortcutStyle.inputBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(ShortcutStyle.inputBorder, lineWidth: 1)
            }

            KeyboardShortcuts.Recorder(for: shortcut) { _ in
                shortcutDisplayRefresh += 1
            }
                .frame(width: ShortcutLayout.shortcutInputWidth, height: 32)
                .opacity(0.01)
        }
        .frame(width: ShortcutLayout.shortcutInputWidth, height: 32, alignment: .leading)
    }

    private func shortcutTokens(for shortcut: KeyboardShortcuts.Name, refresh: Int) -> [String] {
        _ = refresh
        guard let shortcut = KeyboardShortcuts.getShortcut(for: shortcut) else { return [] }
        return Array(String(describing: shortcut)).map(String.init)
    }

    private func keycap(_ label: String) -> some View {
        Text(label)
            .font(.system(size: 12, weight: .medium, design: .monospaced))
            .foregroundStyle(ShortcutStyle.primaryText)
            .frame(minWidth: 24, minHeight: 22)
            .background(ShortcutStyle.keycapBackground, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(ShortcutStyle.keycapBorder, lineWidth: 1)
            }
    }

    // MARK: - Modifier Key Recording

    private var modifierKeyRecordingCard: some View {
        settingsCard {
            modifierHeader
            divider

            modifierKeyRow(
                title: "Dictation",
                key: $pushToTalkKey,
                holdEnabled: $pushToTalkHoldEnabled,
                toggleEnabled: $pushToTalkToggleEnabled,
                tapCount: $pushToTalkTapCount,
                holdStartDelay: $pushToTalkHoldStartDelay,
                keyStore: {
                    SettingsStorage.shared.pushToTalkKey = $0
                    NotificationCenter.default.post(name: .pushToTalkKeyChanged, object: $0)
                },
                holdEnabledStore: {
                    SettingsStorage.shared.pushToTalkHoldEnabled = $0
                    NotificationCenter.default.post(name: .pushToTalkModeChanged, object: nil)
                },
                toggleEnabledStore: {
                    SettingsStorage.shared.pushToTalkToggleEnabled = $0
                    NotificationCenter.default.post(name: .pushToTalkModeChanged, object: nil)
                },
                tapCountStore: {
                    SettingsStorage.shared.pushToTalkToggleTapCount = $0
                    NotificationCenter.default.post(name: .pushToTalkTapCountChanged, object: $0)
                },
                holdStartDelayStore: {
                    SettingsStorage.shared.pushToTalkHoldStartDelaySeconds = $0
                    NotificationCenter.default.post(name: .pushToTalkHoldStartDelayChanged, object: $0)
                }
            )
            divider

            modifierKeyRow(
                title: "Translation",
                key: $translationPushToTalkKey,
                holdEnabled: $translationPushToTalkHoldEnabled,
                toggleEnabled: $translationPushToTalkToggleEnabled,
                tapCount: $translationPushToTalkTapCount,
                holdStartDelay: $translationPushToTalkHoldStartDelay,
                keyStore: {
                    SettingsStorage.shared.translationPushToTalkKey = $0
                    NotificationCenter.default.post(name: .translationPushToTalkKeyChanged, object: $0)
                },
                holdEnabledStore: {
                    SettingsStorage.shared.translationPushToTalkHoldEnabled = $0
                    NotificationCenter.default.post(name: .translationPushToTalkModeChanged, object: nil)
                },
                toggleEnabledStore: {
                    SettingsStorage.shared.translationPushToTalkToggleEnabled = $0
                    NotificationCenter.default.post(name: .translationPushToTalkModeChanged, object: nil)
                },
                tapCountStore: {
                    SettingsStorage.shared.translationPushToTalkToggleTapCount = $0
                    NotificationCenter.default.post(name: .translationPushToTalkTapCountChanged, object: $0)
                },
                holdStartDelayStore: {
                    SettingsStorage.shared.translationPushToTalkHoldStartDelaySeconds = $0
                    NotificationCenter.default.post(name: .translationPushToTalkHoldStartDelayChanged, object: $0)
                }
            )
        }
    }

    private var modifierHeader: some View {
        HStack(spacing: 0) {
            headerCell("Action", width: ShortcutLayout.modifierTitleColumn)
            headerCell("Modifier key", width: ShortcutLayout.modifierKeyColumn)
            headerCell("Tap trigger", width: ShortcutLayout.modifierTapColumn)
            headerCell("Hold key + delay", width: ShortcutLayout.modifierHoldColumn)
        }
        .frame(height: 30)
    }

    private func modifierKeyRow(
        title: String,
        key: Binding<PushToTalkKey>,
        holdEnabled: Binding<Bool>,
        toggleEnabled: Binding<Bool>,
        tapCount: Binding<Int>,
        holdStartDelay: Binding<TimeInterval>,
        keyStore: @escaping (PushToTalkKey) -> Void,
        holdEnabledStore: @escaping (Bool) -> Void,
        toggleEnabledStore: @escaping (Bool) -> Void,
        tapCountStore: @escaping (Int) -> Void,
        holdStartDelayStore: @escaping (TimeInterval) -> Void
    ) -> some View {
        HStack(spacing: 0) {
            rowTitle(title, width: ShortcutLayout.modifierTitleColumn)

            modifierKeyMenu(selection: key)
                .frame(width: ShortcutLayout.modifierKeyColumn, alignment: .leading)

            tapTriggerPicker(
                toggleEnabled: toggleEnabled,
                tapCount: tapCount,
                isDisabled: key.wrappedValue == .none
            )
            .frame(width: ShortcutLayout.modifierTapColumn, alignment: .leading)

            holdTriggerCard(
                key: key.wrappedValue,
                isEnabled: holdEnabled,
                holdStartDelay: holdStartDelay
            )
            .frame(width: ShortcutLayout.modifierHoldColumn, alignment: .leading)
        }
        .frame(height: 77)
        .onChange(of: key.wrappedValue) { _, newValue in
            keyStore(newValue)
        }
        .onChange(of: holdEnabled.wrappedValue) { _, newValue in
            holdEnabledStore(newValue)
        }
        .onChange(of: toggleEnabled.wrappedValue) { _, newValue in
            toggleEnabledStore(newValue)
        }
        .onChange(of: tapCount.wrappedValue) { _, newValue in
            tapCountStore(newValue)
        }
        .onChange(of: holdStartDelay.wrappedValue) { _, newValue in
            holdStartDelayStore(newValue)
        }
    }

    private func modifierKeyMenu(selection: Binding<PushToTalkKey>) -> some View {
        Menu {
            ForEach(PushToTalkKey.allCases) { option in
                Button(option.pickerLabel) {
                    selection.wrappedValue = option
                }
            }
        } label: {
            HStack(spacing: 8) {
                Text(selection.wrappedValue.displayName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(ShortcutStyle.primaryText)
                    .lineLimit(1)

                Spacer(minLength: 4)

                Text("⌄")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(ShortcutStyle.secondaryText)
            }
            .padding(.horizontal, 10)
            .frame(width: 136, height: 30)
            .background(ShortcutStyle.inputBackground, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(ShortcutStyle.inputBorder, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }

    private func tapTriggerPicker(
        toggleEnabled: Binding<Bool>,
        tapCount: Binding<Int>,
        isDisabled: Bool
    ) -> some View {
        countSegmentedPicker(
            selection: tapTriggerSelection(toggleEnabled: toggleEnabled, tapCount: tapCount),
            options: [0, 2, 3],
            width: 154,
            label: { $0 == 0 ? "Off" : "\($0)x" }
        )
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.45 : 1.0)
    }

    private func tapTriggerSelection(toggleEnabled: Binding<Bool>, tapCount: Binding<Int>) -> Binding<Int> {
        Binding<Int>(
            get: {
                guard toggleEnabled.wrappedValue else { return 0 }
                return toggleTapCountOptions.contains(tapCount.wrappedValue) ? tapCount.wrappedValue : 3
            },
            set: { newValue in
                guard newValue != 0 else {
                    toggleEnabled.wrappedValue = false
                    return
                }

                tapCount.wrappedValue = newValue
                toggleEnabled.wrappedValue = true
            }
        )
    }

    private func holdTriggerCard(
        key: PushToTalkKey,
        isEnabled: Binding<Bool>,
        holdStartDelay: Binding<TimeInterval>
    ) -> some View {
        let isAvailable = key != .none
        let isActive = isAvailable && isEnabled.wrappedValue

        return VStack(alignment: .leading, spacing: 7) {
            Button {
                guard isAvailable else { return }
                isEnabled.wrappedValue.toggle()
            } label: {
                HStack(spacing: 8) {
                    checkmarkBadge(isActive: isActive)

                    Text(holdTriggerTitle(key: key))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(ShortcutStyle.primaryText)
                        .lineLimit(1)

                    Spacer(minLength: 6)

                    Text(isActive ? formattedHoldDelay(holdStartDelay.wrappedValue) : "—")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(isActive ? ShortcutStyle.accentSoftText : ShortcutStyle.secondaryText)
                }
                .frame(width: 198, height: 20)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!isAvailable)
            .accessibilityLabel(holdTriggerAccessibilityLabel(key: key, isActive: isActive))

            holdDelaySlider(selection: holdStartDelay, isEnabled: isActive)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(width: 218, height: 64, alignment: .topLeading)
        .background(
            holdTriggerBackground(isActive: isActive),
            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(holdTriggerBorder(isActive: isActive), lineWidth: 1)
        }
        .opacity(isAvailable ? 1.0 : 0.45)
    }

    private func checkmarkBadge(isActive: Bool) -> some View {
        ZStack {
            Circle()
                .fill(isActive ? ShortcutStyle.accent : .clear)
                .overlay {
                    Circle()
                        .stroke(isActive ? ShortcutStyle.accent : ShortcutStyle.secondaryText.opacity(0.45), lineWidth: 1)
                }

            if isActive {
                Text("✓")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .offset(y: -0.5)
            }
        }
        .frame(width: 18, height: 18)
    }

    private func holdDelaySlider(selection: Binding<TimeInterval>, isEnabled: Bool) -> some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let progress = holdDelayProgress(selection.wrappedValue)
            let progressWidth = max(8, width * progress)
            let knobSize: CGFloat = 16
            let knobOffsetX = min(max(progressWidth - knobSize / 2, 0), width - knobSize)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(ShortcutStyle.sliderTrack)
                    .frame(height: 4)

                Capsule()
                    .fill(isEnabled ? ShortcutStyle.accent : ShortcutStyle.secondaryText.opacity(0.3))
                    .frame(width: progressWidth, height: 4)

                Circle()
                    .fill(isEnabled ? ShortcutStyle.accent : ShortcutStyle.secondaryText.opacity(0.5))
                    .frame(width: knobSize, height: knobSize)
                    .overlay {
                        Circle()
                            .stroke(Color.white.opacity(0.5), lineWidth: 1)
                    }
                    .offset(x: knobOffsetX)
            }
            .frame(width: width, height: 18, alignment: .center)
            .contentShape(Rectangle())
            // The settings window is movable-by-background; without this, dragging
            // the custom slider drags the whole window instead of the knob.
            .background(WindowDragBlocker())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard isEnabled else { return }
                        selection.wrappedValue = holdDelayValue(at: value.location.x, width: width)
                    }
            )
        }
        .frame(width: 198, height: 18)
    }

    private func holdDelayProgress(_ value: TimeInterval) -> CGFloat {
        CGFloat((min(max(value, 0.5), 2.0) - 0.5) / 1.5)
    }

    private func holdDelayValue(at x: CGFloat, width: CGFloat) -> TimeInterval {
        guard width > 0 else { return 0.5 }
        let progress = min(max(x / width, 0), 1)
        let rawValue = 0.5 + TimeInterval(progress) * 1.5
        return (rawValue * 10).rounded() / 10
    }

    // MARK: - Cancel Recording

    private var cancelRecordingCard: some View {
        settingsCard {
            HStack(spacing: 0) {
                rowTitle("Cancel Recording", width: ShortcutLayout.cancelTitleColumn)

                booleanSegmentedPicker(
                    selection: $escapeCancelEnabled,
                    falseLabel: "None",
                    trueLabel: "Esc",
                    width: 150
                )
                .frame(width: ShortcutLayout.cancelKeyColumn, alignment: .leading)

                countSegmentedPicker(
                    selection: $escapeCancelPressCount,
                    options: escapePressCountOptions,
                    width: 104
                )
                .disabled(!escapeCancelEnabled)
                .opacity(escapeCancelEnabled ? 1.0 : 0.45)
                .frame(width: ShortcutLayout.cancelTriggerColumn, alignment: .leading)

                saveAudioControl
                    .frame(width: ShortcutLayout.cancelSaveAudioColumn, alignment: .leading)

                Spacer(minLength: 0)
            }
            .frame(height: 50)
        }
        .onChange(of: escapeCancelEnabled) { _, newValue in
            SettingsStorage.shared.escapeCancelEnabled = newValue
            if !newValue {
                EscapeCancelService.shared.deactivate()
            }
        }
        .onChange(of: escapeCancelPressCount) { _, newValue in
            SettingsStorage.shared.escapeCancelPressCount = newValue
        }
        .onChange(of: escapeCancelSaveAudio) { _, newValue in
            SettingsStorage.shared.escapeCancelSaveAudio = newValue
        }
    }

    private var saveAudioControl: some View {
        Button {
            guard escapeCancelEnabled else { return }
            escapeCancelSaveAudio.toggle()
        } label: {
            HStack(spacing: 8) {
                ZStack(alignment: escapeCancelSaveAudio ? .trailing : .leading) {
                    Capsule()
                        .fill(escapeCancelSaveAudio ? ShortcutStyle.accent : ShortcutStyle.segmentBackground)
                        .frame(width: 34, height: 20)

                    Circle()
                        .fill(.white)
                        .frame(width: 14, height: 14)
                        .padding(.horizontal, 3)
                }
                .frame(width: 34, height: 20)

                Text("Save audio")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(ShortcutStyle.secondaryText)
            }
            .frame(height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!escapeCancelEnabled)
        .opacity(escapeCancelEnabled ? 1.0 : 0.45)
    }

    // MARK: - Shared Controls

    private func settingsCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            content()
        }
        .frame(width: ShortcutLayout.contentWidth)
        .background(ShortcutStyle.cardBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(ShortcutStyle.separator, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var divider: some View {
        Rectangle()
            .fill(ShortcutStyle.separator)
            .frame(width: ShortcutLayout.contentWidth, height: 1)
    }

    private func headerCell(_ title: String, width: CGFloat) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(ShortcutStyle.tertiaryText)
            .frame(width: width, height: 30, alignment: .leading)
            .padding(.leading, 14)
    }

    private func rowTitle(_ title: String, width: CGFloat) -> some View {
        Text(title)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(ShortcutStyle.primaryText)
            .lineLimit(1)
            .frame(width: width, alignment: .leading)
            .padding(.leading, 14)
    }

    private func countSegmentedPicker(
        selection: Binding<Int>,
        options: [Int],
        width: CGFloat,
        label: @escaping (Int) -> String = { "\($0)x" }
    ) -> some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.self) { option in
                segmentButton(
                    title: label(option),
                    isSelected: selection.wrappedValue == option,
                    width: width / CGFloat(options.count)
                ) {
                    selection.wrappedValue = option
                }
            }
        }
        .padding(2)
        .frame(width: width, height: 28)
        .background(ShortcutStyle.segmentBackground, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(ShortcutStyle.inputBorder, lineWidth: 1)
        }
    }

    private func booleanSegmentedPicker(
        selection: Binding<Bool>,
        falseLabel: String,
        trueLabel: String,
        width: CGFloat
    ) -> some View {
        HStack(spacing: 0) {
            segmentButton(title: falseLabel, isSelected: !selection.wrappedValue, width: width / 2) {
                selection.wrappedValue = false
            }

            segmentButton(title: trueLabel, isSelected: selection.wrappedValue, width: width / 2) {
                selection.wrappedValue = true
            }
        }
        .padding(2)
        .frame(width: width, height: 28)
        .background(ShortcutStyle.segmentBackground, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(ShortcutStyle.inputBorder, lineWidth: 1)
        }
    }

    private func segmentButton(
        title: String,
        isSelected: Bool,
        width: CGFloat,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isSelected ? Color.white : ShortcutStyle.secondaryText)
                .frame(width: width - 4, height: 24)
                .background(
                    isSelected ? ShortcutStyle.accent : Color.clear,
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                )
        }
        .buttonStyle(.plain)
    }

    private func formattedHoldDelay(_ value: TimeInterval) -> String {
        String(format: "%.1f s", value)
    }

    private func holdTriggerTitle(key: PushToTalkKey) -> String {
        guard key != .none else { return "Choose modifier key" }
        return "Hold \(key.displayName)"
    }

    private func holdTriggerAccessibilityLabel(key: PushToTalkKey, isActive: Bool) -> String {
        guard key != .none else { return "Choose a modifier key before enabling hold trigger" }
        return isActive ? "Disable hold trigger for \(key.displayName)" : "Enable hold trigger for \(key.displayName)"
    }

    private func holdTriggerBackground(isActive: Bool) -> Color {
        isActive ? ShortcutStyle.holdActiveBackground : ShortcutStyle.inputBackground
    }

    private func holdTriggerBorder(isActive: Bool) -> Color {
        isActive ? ShortcutStyle.accent.opacity(0.72) : ShortcutStyle.inputBorder
    }
}

private enum ShortcutLayout {
    static let contentWidth: CGFloat = 715
    static let contentLeading: CGFloat = 22
    static let contentTop: CGFloat = 6

    static let actionTitleColumn: CGFloat = 216
    static let actionShortcutColumn: CGFloat = 236
    static let actionTriggerColumn: CGFloat = 150
    static let actionTriggerWidth: CGFloat = 150
    static let shortcutInputWidth: CGFloat = 224

    static let modifierTitleColumn: CGFloat = 162
    static let modifierKeyColumn: CGFloat = 146
    static let modifierTapColumn: CGFloat = 164
    static let modifierHoldColumn: CGFloat = 243

    static let cancelTitleColumn: CGFloat = 216
    static let cancelKeyColumn: CGFloat = 162
    static let cancelTriggerColumn: CGFloat = 116
    static let cancelSaveAudioColumn: CGFloat = 160
}

private enum ShortcutStyle {
    static let windowBackground = Color(hex: 0x1C1C1E)
    static let cardBackground = Color(hex: 0x2C2C2E)
    static let inputBackground = Color(hex: 0x242428)
    static let segmentBackground = Color(hex: 0x242428)
    static let keycapBackground = Color(hex: 0x3A3A40).opacity(0.55)
    static let holdActiveBackground = Color(hex: 0x2B2028)
    static let sliderTrack = Color(hex: 0x4A3945)

    static let primaryText = Color(hex: 0xF5F5F7)
    static let secondaryText = Color(hex: 0x98989D)
    static let tertiaryText = Color(hex: 0x636366)
    static let accent = Color(hex: 0xFF5C7E)
    static let accentSoft = Color(hex: 0x3A2129)
    static let accentSoftText = Color(hex: 0xFFD2DE)
    static let accentBorder = Color(hex: 0xFF5C7E).opacity(0.25)
    static let separator = Color.white.opacity(0.08)
    static let inputBorder = Color(hex: 0x393940)
    static let keycapBorder = Color.white.opacity(0.1)
}

private extension Color {
    init(hex: UInt, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}

extension Notification.Name {
    static let pushToTalkKeyChanged = Notification.Name("pushToTalkKeyChanged")
    static let translationPushToTalkKeyChanged = Notification.Name("translationPushToTalkKeyChanged")
    static let pushToTalkTapCountChanged = Notification.Name("pushToTalkTapCountChanged")
    static let translationPushToTalkTapCountChanged = Notification.Name("translationPushToTalkTapCountChanged")
    static let pushToTalkModeChanged = Notification.Name("pushToTalkModeChanged")
    static let translationPushToTalkModeChanged = Notification.Name("translationPushToTalkModeChanged")
    static let pushToTalkHoldStartDelayChanged = Notification.Name("pushToTalkHoldStartDelayChanged")
    static let translationPushToTalkHoldStartDelayChanged =
        Notification.Name("translationPushToTalkHoldStartDelayChanged")
}

#Preview {
    ShortcutsSettingsView()
        .frame(width: 759, height: 666)
}

/// Marks its region as non-window-draggable. The settings window uses
/// `isMovableByWindowBackground = true`, and SwiftUI shapes leave
/// `mouseDownCanMoveWindow == true`, so dragging a custom control (e.g. the
/// hold-delay slider) would drag the whole window. Placed as a `.background`,
/// this reports the region as non-draggable while passing mouse events through
/// to the SwiftUI gesture above it.
private struct WindowDragBlocker: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { BlockerView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class BlockerView: NSView {
        override var mouseDownCanMoveWindow: Bool { false }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
