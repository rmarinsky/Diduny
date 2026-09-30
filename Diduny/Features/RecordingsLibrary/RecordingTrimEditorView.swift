import SwiftUI

struct RecordingTrimEditorView: View {
    @Binding var editor: AudioTrimEditorState
    let recordingID: UUID
    let fileURL: URL
    let onCancel: () -> Void
    let onSave: () -> Void
    @FocusState private var focusedField: Bool?
    @State private var playback = AudioPlaybackService.shared
    @State private var dragging = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Trim recording").font(.headline)
                    Text("Select the part to keep").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            HStack(spacing: 8) {
                Button {
                    playback.togglePlayback(recordingId: recordingID, fileURL: fileURL, trimRange: editor.range)
                } label: {
                    Label(playback.isPlaying && playback.playingRecordingId == recordingID ? "Pause" : "Preview", systemImage: playback.isPlaying ? "pause.fill" : "play.fill")
                }
                Button { playback.stop(); editor.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                    .help("Undo (⌘Z)").accessibilityLabel("Undo trim change")
                    .keyboardShortcut("z", modifiers: .command).disabled(!editor.canUndo)
                Button { playback.stop(); editor.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                    .help("Redo (⇧⌘Z)").accessibilityLabel("Redo trim change")
                    .keyboardShortcut("z", modifiers: [.command, .shift]).disabled(!editor.canRedo)
                Spacer(minLength: 0)
                Text("Original \(AudioTrimEditorState.format(editor.duration))")
                    .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
            }.controlSize(.small)
            timeline
            HStack {
                timeField("Start", text: Binding(get: { editor.startText }, set: { editor.editTime($0, isStart: true) }), isStart: true)
                timeField("End", text: Binding(get: { editor.endText }, set: { editor.editTime($0, isStart: false) }), isStart: false)
            }
            if editor.hasInvalidTime {
                Text("Enter a valid time within the original recording, with Start before End.")
                    .font(.caption).foregroundStyle(.red)
            }
            HStack {
                Text("Selected duration")
                Spacer()
                Text(AudioTrimEditorState.format(editor.range.durationSeconds)).monospacedDigit().fontWeight(.semibold)
            }
            Divider()
            Text("The original is kept. Earlier transcripts remain in history.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Restore original") { playback.stop(); editor.restoreOriginal() }
                    .buttonStyle(.link).disabled(editor.rangeToSave == nil)
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Save") { if editor.commitTimeFields() { playback.stop(); onSave() } }
                    .disabled(!editor.isDirty || editor.hasInvalidTime)
                    .buttonStyle(.borderedProminent)
            }.controlSize(.small)
        }
        .onChange(of: focusedField) { old, new in
            if old != nil { editor.endGesture() }
            if new != nil { editor.beginGesture() }
        }
        .onDisappear { if playback.playingRecordingId == recordingID { playback.stop() } }
    }

    private var timeline: some View {
        VStack(spacing: 6) {
            GeometryReader { geometry in
                let width = max(geometry.size.width - 14, 1)
                let start = editor.range.startSeconds / editor.duration * width
                let end = editor.range.endSeconds / editor.duration * width
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 6).fill(Color(.textBackgroundColor))
                    Path { path in
                        for tick in 0 ... 32 {
                            let x = 7 + width * Double(tick) / 32
                            path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: 68))
                        }
                    }.stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                    Rectangle().fill(Color.accentColor.opacity(0.22)).frame(width: max(end - start, 1)).offset(x: 7 + start)
                    handle(isStart: true, position: start, width: width)
                    handle(isStart: false, position: end, width: width)
                }
            }.frame(height: 68).coordinateSpace(name: "trimTimeline")
            HStack {
                ForEach(0 ... 4, id: \.self) { tick in
                    if tick > 0 { Spacer(minLength: 0) }
                    Text(AudioTrimEditorState.format(editor.duration * Double(tick) / 4))
                        .font(.system(size: 9)).monospacedDigit().foregroundStyle(.secondary)
                }
            }
        }
    }

    private func handle(isStart: Bool, position: Double, width: Double) -> some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(Color.accentColor).frame(width: 14)
            .overlay { Capsule().fill(.white).frame(width: 2, height: 18) }
            .offset(x: position)
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("trimTimeline"))
                .onChanged { value in
                    if !dragging { editor.beginGesture(); dragging = true; playback.stop() }
                    let seconds = (value.location.x - 7) / width * editor.duration
                    if isStart { editor.setStart(seconds) } else { editor.setEnd(seconds) }
                }
                .onEnded { _ in editor.endGesture(); dragging = false })
            .accessibilityElement()
            .accessibilityLabel(isStart ? "Start trim handle" : "End trim handle")
            .accessibilityValue(AudioTrimEditorState.format(isStart ? editor.range.startSeconds : editor.range.endSeconds))
            .accessibilityAdjustableAction { direction in
                playback.stop()
                let delta: Double = direction == .increment ? 1 : -1
                if isStart { editor.setStart(editor.range.startSeconds + delta) }
                else { editor.setEnd(editor.range.endSeconds + delta) }
            }
    }

    private func timeField(_ title: String, text: Binding<String>, isStart: Bool) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextField("hh:mm:ss", text: text).monospacedDigit()
                .accessibilityLabel("\(title) time")
                .focused($focusedField, equals: isStart)
                .onSubmit { _ = editor.commitTimeFields() }
                .onChange(of: text.wrappedValue) { _, _ in playback.stop() }
        }
    }
}
