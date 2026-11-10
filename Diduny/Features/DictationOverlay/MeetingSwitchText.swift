import Foundation

/// Every sentence a mid-meeting switch shows (`mid-meeting-switching.md`). Marker lines stay in the panel.
enum MeetingSwitchText {
    struct Line: Equatable {
        let message: String
        var linkTitle: String?
    }

    /// 06:22, or 1:06:22 past an hour.
    static func clock(_ seconds: TimeInterval) -> String {
        let total = max(Int(seconds), 0)
        let time = String(format: "%02d:%02d", total / 60 % 60, total % 60)
        return total >= 3600 ? "\(total / 3600):\(time)" : time
    }

    /// A segment's name when the segment changed, the engine's inside one, the engine's in Translate meeting.
    static func name(of target: MeetingEngineTarget, from: MeetingEngineTarget?, translateMeeting: Bool) -> String {
        if translateMeeting || from?.segment == target.segment { return MeetingPanelState.name(target.engine) }
        return EngineCaptions.startsIn(target.segment).title
    }

    static func marker(_ marker: MeetingSwitchMarker, translateMeeting: Bool) -> String {
        let time = clock(marker.elapsed)
        switch marker.kind {
        case let .pair(label):
            return String(localized: "\(time) · now \(label)")
        case let .switched(from, to):
            let name = name(of: to, from: from, translateMeeting: translateMeeting)
            return String(localized: "\(time) · switched to \(name)")
        }
    }

    static func gapNote(_ marker: MeetingSwitchMarker) -> String? {
        guard let start = marker.gapStart else { return nil }
        guard let end = marker.gapEnd else {
            return String(localized: "No text here until you switch back. All of it goes into the transcript after Stop.")
        }
        let length = clock(end - start)
        return String(localized: "No live text for \(length). It goes into the transcript after Stop.")
    }

    static func line(
        _ display: MeetingSwitchDisplay, translateMeeting: Bool, canUseAppleSpeech: Bool, canUseElevenLabs: Bool
    ) -> Line? {
        let current = name(of: display.running, from: nil, translateMeeting: translateMeeting)
        // No link without something to retry.
        let tryAgain = display.failedTarget == nil ? nil : String(localized: "Try again")
        switch display.failure {
        case .noInternet:
            if !display.runningIsLive {
                return Line(message: String(localized: "No internet. Still recording without live text."), linkTitle: tryAgain)
            }
            return Line(message: String(localized: "No internet. Still on \(current)."), linkTitle: tryAgain)
        case .noModel:
            return Line(message: String(localized: "Whisper has no model yet. Still on \(current)."),
                        linkTitle: canUseAppleSpeech ? String(localized: "Use Apple Speech") : nil)
        case .noQuota:
            return Line(message: String(localized: "Diduny quota used up. Still on \(current)."),
                        linkTitle: canUseElevenLabs && !translateMeeting ? String(localized: "Use ElevenLabs") : nil)
        case .signedOut:
            return Line(message: String(localized: "Sign in to use Diduny Cloud. Still on \(current)."))
        case .needsKey:
            return Line(message: String(localized: "Check your ElevenLabs key. Still on \(current)."))
        case .timedOut, .other:
            return Line(message: String(localized: "Couldn't switch. Still on \(current)."), linkTitle: tryAgain)
        case nil:
            break
        }
        switch display.note {
        case .quotaMoved:
            return Line(message: String(localized: "Diduny quota used up. Recording continues without live text."))
        case .offline where display.running.segment == .cloud:
            return Line(message: String(localized: "No internet. Recording continues."),
                        linkTitle: translateMeeting ? nil : String(localized: "Use Local"))
        default:
            return nil
        }
    }

    /// Translate meeting off Diduny Cloud with text on screen.
    static func translateCalmWithText(pair: TranslationLanguagePair, locale: Locale) -> String {
        let language = locale.localizedString(forLanguageCode: pair.languageB) ?? pair.languageB.uppercased()
        return String(localized: "Text so far comes back with Diduny Cloud. What is said now is translated into \(language) after Stop.")
    }
}
