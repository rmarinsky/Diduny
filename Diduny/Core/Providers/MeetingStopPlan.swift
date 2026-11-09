import Foundation

/// What Stop does with a meeting (ADR-0013 D3). Pure over the history and the resolved after-Stop engine.
enum MeetingStopPlan: Equatable {
    enum Reason: Equatable { case mixed, liveDraft, recordOnly, liveTextRejected }

    case keepLiveText(EngineID)
    case wholeRecording(EngineID, modelID: String?, reason: Reason)
    case saveOnly

    /// Roman, 2026-11-09: the mode selected at Stop replaces the earlier ones and transcribes the whole recording.
    /// Cloud keeps its live text only for one clean span; Local never uploads; Record only runs its engine.
    /// `resolve` is ADR-0012 D3 at Stop time for one engine.
    static func plan(
        history: MeetingEngineHistory,
        recordOnlyEngine: EngineID,
        resolve: (EngineID) -> EffectiveEngineResolver.Result,
        liveTextAccepted: Bool,
        hasLiveText: Bool = true
    ) -> MeetingStopPlan {
        guard let last = history.spans.last else { return .saveOnly }
        let single = history.spans.count == 1
        let clean = single && !last.disrupted
        if clean, last.target.isLive, last.target.segment == .cloud, liveTextAccepted {
            return .keepLiveText(last.target.engine)
        }
        let reason: Reason = !clean ? .mixed
            : !last.target.isLive ? .recordOnly
            : last.target.segment == .thisMac ? .liveDraft : .liveTextRejected
        func runnable(_ engine: EngineID) -> (EngineID, String?)? {
            switch resolve(engine) {
            case let .engine(id, model), let .fallback(id, model, _): (id, model)
            case .none: nil
            }
        }
        func isLocal(_ engine: EngineID) -> Bool { engine != .didunyCloud && engine != .elevenLabs }

        let chosen: (EngineID, String?)?
        switch last.target {
        case let .live(engine) where last.target.segment == .cloud:
            // Only that engine itself; with nothing to run, a single span's text stays (review rule).
            if case let .engine(id, model) = resolve(engine) {
                chosen = (id, model)
            } else if single, hasLiveText {
                return .keepLiveText(engine)
            } else {
                chosen = nil
            }
        case let .live(engine):
            // Local: on this Mac only. Its own engine after Stop, else a local Record only engine, else the best ready one.
            let candidates = [engine] + (isLocal(recordOnlyEngine) ? [recordOnlyEngine] : []) + [.parakeet, .whisper, .appleSpeech]
            chosen = candidates.compactMap(runnable).first { isLocal($0.0) }
        case let .afterStopOnly(engine):
            chosen = runnable(engine)
        }
        guard let (engine, model) = chosen else { return .saveOnly }
        return .wholeRecording(engine, modelID: model, reason: reason)
    }
}

extension MeetingStopPlan {
    static var saveOnlyLine: String {
        String(localized: "The whole recording is saved. No engine on this Mac can make the transcript yet. Download a model in Local models.")
    }

    /// The hand-off text after Stop, per `mid-meeting-switching.md`. Nil keeps the plain line.
    func stopLine(preview: EngineID?, mode: MeetingSegment? = nil) -> String? {
        switch self {
        case .keepLiveText, .saveOnly:
            return nil
        case let .wholeRecording(engine, _, reason):
            let name = MeetingPanelState.name(engine)
            let onThisMac = engine != .didunyCloud && engine != .elevenLabs
            switch (reason, onThisMac) {
            case (.mixed, true) where mode != nil:
                let modeName = EngineCaptions.startsIn(mode!).title
                return String(localized: "You ended on \(modeName), so \(name) makes one transcript from the whole recording, on this Mac. It replaces the live text.")
            case (.mixed, false) where mode != nil:
                let modeName = EngineCaptions.startsIn(mode!).title
                return String(localized: "You ended on \(modeName), so \(name) makes one transcript from the whole recording, in the cloud. It replaces the live text.")
            case (.mixed, true):
                return String(localized: "The engine changed during this meeting, so \(name) makes one transcript from the whole recording, on this Mac. It replaces the live text.")
            case (.mixed, false):
                return String(localized: "The engine changed during this meeting, so \(name) makes one transcript from the whole recording, in the cloud. It replaces the live text.")
            case (.liveDraft, true), (.liveTextRejected, true):
                let from = preview.map(MeetingPanelState.name) ?? name
                return String(localized: "The live text was a preview from \(from). \(name) is making the transcript of the whole meeting, on this Mac. It replaces the live text.")
            case (.liveDraft, false), (.liveTextRejected, false):
                let from = preview.map(MeetingPanelState.name) ?? name
                return String(localized: "The live text was a preview from \(from). \(name) is making the transcript of the whole meeting, in the cloud. It replaces the live text.")
            case (.recordOnly, true):
                return String(localized: "\(name) is making the transcript of the whole meeting, on this Mac.")
            case (.recordOnly, false):
                return String(localized: "\(name) is making the transcript of the whole meeting, in the cloud.")
            }
        }
    }
}

/// One part of a Translate meeting's saved text, in time order (ADR-0013 D4).
enum TranslatePart: Equatable, Sendable {
    case live(text: String)
    case afterStop(range: AudioTrimRange?, engine: EngineID)
}

enum TranslatePlan {
    /// `liveTexts[i]` is the live text of span `i`. Empty when the whole recording must be translated in one go:
    /// after skipped chunks, frame offsets no longer match the stitched file.
    static func plan(
        history: MeetingEngineHistory,
        liveTexts: [Int: String],
        afterStopEngine: EngineID,
        totalFrames: Int,
        sampleRate: Double,
        skippedChunks: Int
    ) -> [TranslatePart] {
        guard skippedChunks == 0, sampleRate > 0 else { return [] }
        var parts: [TranslatePart] = []
        func addAudio(from start: Int, to end: Int, engine: EngineID) {
            guard end > start else { return }
            parts.append(.afterStop(
                range: AudioTrimRange(startSeconds: Double(start) / sampleRate, endSeconds: Double(end) / sampleRate),
                engine: engine
            ))
        }
        for (index, span) in history.spans.enumerated() {
            let end = index + 1 < history.spans.count ? history.spans[index + 1].startFrame : totalFrames
            guard end > span.startFrame else { continue }
            guard span.target.isLive else {
                addAudio(from: span.startFrame, to: end, engine: span.target.engine)
                continue
            }
            if let text = liveTexts[index], !text.isEmpty { parts.append(.live(text: text)) }
            if let failed = span.failedAtFrame {
                addAudio(from: max(failed, span.startFrame), to: end, engine: afterStopEngine)
            }
        }
        return parts
    }
}
