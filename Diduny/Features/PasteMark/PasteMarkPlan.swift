import AppKit

/// The caret's position in the focused text element: the insertion index and the rect
/// (AppKit coordinates) of the character before it.
struct CaretPosition: Equatable, Sendable {
    let location: Int
    let rect: CGRect
}

/// AX geometry of the focused text element. Blocking; call off the main thread.
protocol CaretGeometry: Sendable {
    func caret() -> CaretPosition?
}

/// The logo after Stop (docs/design/stop-animation, "Logo badge"): which surface plays it,
/// its timeline and its state. Pure, so it is tested without a real caret.
enum PasteMarkPlan {
    /// Where the "done" (closed ring and pulse) plays.
    enum Surface: Equatable {
        /// Next to the pasted text.
        case caret
        /// The logo in the panel header (meetings, or no caret geometry).
        case panelHeader
        /// Nothing was pasted.
        case none
    }

    static func surface(isMeeting: Bool, pasted: Bool, caretKnown: Bool) -> Surface {
        if isMeeting { return .panelHeader }
        guard pasted else { return .none }
        return caretKnown ? .caret : .panelHeader
    }

    /// The logo disc, one size for every mode.
    static let disc: CGFloat = 42
    /// Room around the disc for the 1.15 pulse.
    static let panelMargin: CGFloat = 5

    struct Timeline: Equatable {
        var appear: TimeInterval
        var ringClose: TimeInterval
        var glide: TimeInterval
        var pulseStart: TimeInterval
        var pulse: TimeInterval
        var fadeStart: TimeInterval
        var fade: TimeInterval
        var total: TimeInterval {
            fadeStart + fade
        }
    }

    /// README table: ring 200 ms, glide 220 ms, pulse M8 at 220 ms, fade 150 ms from 680 ms.
    /// Reduce Motion: no glide or pulse, the ring shows in 120 ms, then the same fade.
    static func timeline(reduceMotion: Bool) -> Timeline {
        if reduceMotion {
            return Timeline(appear: 0.12, ringClose: 0.12, glide: 0, pulseStart: 0, pulse: 0, fadeStart: 0.68, fade: 0.15)
        }
        return Timeline(
            appear: 0.18, ringClose: 0.20, glide: 0.22, pulseStart: 0.22,
            pulse: DS.Motion.m8SuccessPulse.duration, fadeStart: 0.68, fade: 0.15
        )
    }

    /// The pasted end must be found within this, or the logo stays put (no late slide).
    static let glideBudget: TimeInterval = 0.3

    struct Landing: Equatable {
        var glides: Bool
        /// Seconds from the paste.
        var pulseAt: TimeInterval?
        var fadeAt: TimeInterval
    }

    /// The pulse plays where the logo ends: after the glide, or at once when it stays put.
    /// `endFoundAfter`: when the poll found the pasted end, nil if it never did.
    static func landing(endFoundAfter: TimeInterval?, reduceMotion: Bool) -> Landing {
        let timeline = timeline(reduceMotion: reduceMotion)
        if reduceMotion { return Landing(glides: false, pulseAt: nil, fadeAt: timeline.fadeStart) }
        guard let found = endFoundAfter, found <= glideBudget else {
            return Landing(glides: false, pulseAt: timeline.pulseStart, fadeAt: timeline.fadeStart)
        }
        let pulseAt = max(found + timeline.glide, timeline.pulseStart)
        return Landing(glides: true, pulseAt: pulseAt, fadeAt: pulseAt + timeline.fadeStart - timeline.pulseStart)
    }

    /// A meeting's Stop on the floating panel (Roman, 2026-11-10): the header logo's rim arc while
    /// the recording is saved, then the ring closes, pulses once and the panel goes by itself.
    enum HeaderLanding: Equatable {
        case saving
        /// Saved, and the transcript is done or queued; `line` is the header status.
        case done(line: String)
    }

    static func logo(for end: HeaderLanding) -> LogoBadgePhase {
        end == .saving ? .waiting : .done
    }

    /// The panel goes when the landing fades: no caret, so all of it plays in the header.
    static func headerLandingDismissDelay(reduceMotion: Bool) -> TimeInterval {
        timeline(reduceMotion: reduceMotion).fadeStart
    }

    /// How a dictation or its translation ends on the floating panel (Roman, 2026-11-09: no result
    /// window, the text is already pasted or copied).
    enum DictationEnd: Equatable {
        /// The logo plays at the caret; the panel closes at once.
        case closeNow
        /// No caret: the same landing in the panel header (ring, one pulse), then the panel goes.
        case headerLogo
        /// Auto-paste is on but the paste failed: the Copied outcome stays, it is the only message.
        case copiedOutcome
    }

    static func dictationEnd(autoPaste: Bool, pasted: Bool, caretKnown: Bool) -> DictationEnd {
        if pasted { return caretKnown ? .closeNow : .headerLogo }
        return autoPaste ? .copiedOutcome : .headerLogo
    }

    /// The outcome header logo pulses on appear when it is the only "done" signal: every dictation
    /// outcome, or a meeting whose transcript is already ready (otherwise it pulses on "Transcript ready").
    static func headerPulsesOnAppear(isMeeting: Bool, transcriptReady: Bool) -> Bool {
        isMeeting ? transcriptReady : true
    }

    /// Apps that answer with a whole line, field or window instead of one character
    /// (terminals, some web views) give no caret; the panel plays instead.
    static func plausibleCaretRect(_ rect: CGRect?) -> CGRect? {
        guard let rect, !rect.isEmpty, rect.height <= 80, rect.width <= 200 else { return nil }
        return rect
    }

    /// Typing clears the logo; a ⌘ chord (including our own ⌘V) does not.
    static func keyDownClears(modifiers: NSEvent.ModifierFlags) -> Bool {
        !modifiers.contains(.command)
    }

    enum Phase: Equatable {
        case idle
        /// Asking AX where the caret is.
        case locating
        /// Logo at the caret, the arc spins while the text is finalized.
        case waiting
        /// After the paste: ring, glide, pulse, fade.
        case landing
    }

    enum Event {
        case finalizing
        case caretFound
        case caretMissing
        case pasted
        case notPasted
        case typed
        case newRecording
        case finished
    }

    static func next(_ phase: Phase, _ event: Event) -> Phase {
        switch (phase, event) {
        case (_, .finalizing): .locating
        case (.locating, .caretFound): .waiting
        case (.waiting, .pasted): .landing
        case (.locating, .caretMissing), (.locating, .pasted): .idle
        case (_, .notPasted), (_, .typed), (_, .newRecording), (_, .finished): .idle
        default: phase
        }
    }

    /// After ⌘V the caret moves asynchronously: poll until it passes `before`, up to `timeout`.
    /// Nil leaves the logo where it is.
    static func pollPastedEnd(
        geometry: any CaretGeometry,
        before: Int,
        timeout: Duration = .milliseconds(300),
        interval: Duration = .milliseconds(16)
    ) async -> CaretPosition? {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !Task.isCancelled {
            if let now = geometry.caret(), now.location > before { return now }
            guard clock.now + interval <= deadline else { return nil }
            try? await Task.sleep(for: interval)
        }
        return nil
    }
}
