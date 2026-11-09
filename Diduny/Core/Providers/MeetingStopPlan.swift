import Foundation

/// What Stop does with a meeting (ADR-0013 D3). Pure over the history and the resolved after-Stop engine.
enum MeetingStopPlan: Equatable {
    enum Reason: Equatable { case mixed, liveDraft, recordOnly, liveTextRejected }

    case keepLiveText(EngineID)
    case wholeRecording(EngineID, modelID: String?, reason: Reason)
    case saveOnly

    /// `keepLiveText` needs one span, a live cloud engine, no disruption and today's acceptance guard.
    static func plan(
        history: MeetingEngineHistory,
        afterStop: EffectiveEngineResolver.Result,
        liveTextAccepted: Bool
    ) -> MeetingStopPlan {
        if history.spans.count == 1, let only = history.spans.first, only.target.isLive,
           only.target.segment == .cloud, !only.disrupted, liveTextAccepted
        {
            return .keepLiveText(only.target.engine)
        }
        let reason: Reason
        if history.spans.count > 1 || history.spans.contains(where: \.disrupted) {
            reason = .mixed
        } else if let only = history.spans.first, !only.target.isLive {
            reason = .recordOnly
        } else if history.spans.first?.target.segment == .thisMac {
            reason = .liveDraft
        } else {
            reason = .liveTextRejected
        }
        switch afterStop {
        case let .engine(engine, modelID), let .fallback(engine, modelID, _):
            return .wholeRecording(engine, modelID: modelID, reason: reason)
        case .none:
            return .saveOnly
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
