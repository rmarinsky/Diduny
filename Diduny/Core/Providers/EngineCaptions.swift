import Foundation

/// Every engine caption and menu subline, derived from `EngineCapabilities` (prototype v9 `modeSub`,
/// `capLine`, `recSub`, `tSub`, `withNote`, `blurb`; design-spec section 12). Pure: no AppKit, no settings.
enum EngineCaptions {
    // MARK: Modes (05 2.1.1)

    /// Caption under a mode's engine field, also the base of its menu subline. `segment` applies to `.meeting`.
    static func caption(job: STTJob, segment: MeetingSegment? = nil, caps: EngineCapabilities) -> String {
        switch job {
        case .dictation: dictation(caps)
        case .dictationTranslation: translation(caps)
        case .meeting: segment == .recordOnly ? afterStop(caps) : liveMeeting(caps)
        case .meetingTranslation: translateMeeting(caps)
        case .file: String(localized: "On this Mac")
        }
    }

    /// Menu row subline: the caption plus the engine note (only menus carry notes).
    static func menuSubline(
        job: STTJob,
        segment: MeetingSegment? = nil,
        caps: EngineCapabilities,
        readiness: EngineReadiness = .ready,
        locale: Locale = EngineLanguages.appLocale
    ) -> String {
        withNote(caption(job: job, segment: segment, caps: caps), caps: caps, readiness: readiness, locale: locale)
    }

    /// Appends " · <note>". An engine that is not downloaded shows only "Not downloaded, <size>" (design-spec 12.1.2).
    /// `locale` formats the size ("480 MB").
    static func withNote(
        _ text: String,
        caps: EngineCapabilities,
        readiness: EngineReadiness = .ready,
        locale: Locale = EngineLanguages.appLocale
    ) -> String {
        if case let .notDownloaded(bytes) = readiness {
            let size = bytes.formatted(.byteCount(style: .file).locale(locale))
            return String(localized: "Not downloaded, \(size)")
        }
        return note(caps).map { "\(text) · \($0)" } ?? text
    }

    /// "Large v3 Turbo, recommended" (Whisper), "recommended" (Parakeet V3), nil otherwise.
    static func note(_ caps: EngineCapabilities) -> String? {
        switch caps.traits.recommended {
        case .none:
            return nil
        case .engine:
            return String(localized: "recommended")
        case let .model(id):
            let name = WhisperModelManager.availableModels.first { $0.name == id }?.displayName ?? id
            return String(localized: "\(name), recommended")
        }
    }

    /// "Starts in" menu row for a meeting segment.
    static func startsIn(_ segment: MeetingSegment) -> (title: String, subline: String) {
        switch segment {
        case .thisMac: (String(localized: "This Mac"), String(localized: "Live text made on this Mac"))
        case .cloud: (String(localized: "Cloud"), String(localized: "Live text from the cloud"))
        case .recordOnly: (String(localized: "Record only"), String(localized: "No live text. Transcript after Stop"))
        }
    }

    // MARK: Live panels (01)

    /// Meeting panel caption under the engine picker.
    static func meetingPanelCaption(segment: MeetingSegment, caps: EngineCapabilities) -> String {
        guard segment == .recordOnly else { return liveMeeting(caps) }
        let afterStop = afterStop(caps)
        return String(localized: "No live text · \(afterStop.prefix(1).lowercased() + afterStop.dropFirst())")
    }

    /// Meeting panel engine menu subline: live segments add " · your key" for a bring-your-own-key engine.
    static func meetingPanelMenuSubline(
        segment: MeetingSegment,
        caps: EngineCapabilities,
        readiness: EngineReadiness = .ready
    ) -> String {
        var text = segment == .recordOnly ? afterStop(caps) : liveMeeting(caps)
        if segment != .recordOnly, caps.traits.obtainedBy == .ownKey {
            text += " · " + String(localized: "your key")
        }
        return withNote(text, caps: caps, readiness: readiness)
    }

    /// Dictation panel caption: Output "Original" (`translating` false) or a language.
    static func dictationPanelCaption(translating: Bool, caps: EngineCapabilities) -> String {
        guard translating else { return dictation(caps) }
        if caps.dictationTranslation == .itself { return String(localized: "Live translation") }
        return caps.liveDictation == .none
            ? String(localized: "Text and translation by Diduny after Stop")
            : String(localized: "You see your words. The translation by Diduny is pasted after Stop")
    }

    // MARK: Command panel and Providers

    /// Command panel engine menu subline, e.g. "Live text, speaker labels, 60 languages".
    static func blurb(_ caps: EngineCapabilities) -> String {
        var parts: [String] = switch caps.liveDictation {
        case .final: [String(localized: "Live text")]
        case .preview: [String(localized: "Live preview")]
        case .none: [String(localized: "After Stop")]
        }
        if caps.speakerLabelsLive { parts.append(String(localized: "speaker labels")) }
        if let count = caps.traits.languages.count {
            parts.append(String(localized: "\(count) languages"))
        } else {
            parts.append(String(localized: "macOS languages"))
        }
        let text = parts.joined(separator: ", ")
        return caps.traits.obtainedBy == .ownKey ? text + ". " + String(localized: "Your key") : text
    }

    /// Providers "Meeting speaker labels" subline when labels come only after Stop with a limit: "After Stop, up to 32".
    static func afterStopSpeakerLabels(_ caps: EngineCapabilities) -> String? {
        guard !caps.speakerLabelsLive, case let .yes(maxSpeakers?) = caps.speakerLabelsAfterStop else { return nil }
        return String(localized: "After Stop, up to \(maxSpeakers)")
    }

    // MARK: Pieces

    private static func dictation(_ caps: EngineCapabilities) -> String {
        switch caps.liveDictation {
        case .final: String(localized: "Text as you speak")
        case .preview: String(localized: "Text as you speak (preview)")
        case .none: String(localized: "Text after Stop")
        }
    }

    private static func translation(_ caps: EngineCapabilities) -> String {
        if caps.dictationTranslation == .itself { return String(localized: "Live translation") }
        return caps.liveDictation == .none ? String(localized: "By Diduny, after Stop") : String(localized: "By Diduny")
    }

    /// `capLine`: live meeting text and live speaker labels. Engines without live text are not offered there.
    private static func liveMeeting(_ caps: EngineCapabilities) -> String {
        let live = caps.liveMeetingText == .preview ? String(localized: "Live text (preview)") : String(localized: "Live text")
        let labels = caps.speakerLabelsLive ? String(localized: "speaker labels") : String(localized: "no speaker labels")
        return "\(live) · \(labels)"
    }

    /// `recSub`: where Record only makes the transcript after Stop, plus speaker labels after Stop.
    private static func afterStop(_ caps: EngineCapabilities) -> String {
        let place = caps.traits.runsOn == .thisMac
            ? String(localized: "After Stop, on this Mac")
            : String(localized: "After Stop, in the cloud")
        guard case .yes = caps.speakerLabelsAfterStop else { return place }
        return String(localized: "\(place), speaker labels")
    }

    /// `tSub`: only an engine with native two-way translation translates a meeting live.
    private static func translateMeeting(_ caps: EngineCapabilities) -> String {
        switch caps.meetingTranslation {
        case .liveBothDirections: String(localized: "Live, both directions, speaker labels")
        case .afterStopIntoSecondLanguage: String(localized: "After Stop, by Diduny, into one language")
        }
    }
}
