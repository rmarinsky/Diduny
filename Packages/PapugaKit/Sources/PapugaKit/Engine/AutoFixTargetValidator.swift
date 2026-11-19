import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import Foundation

struct AXTextRange: Equatable {
    let location: Int
    let length: Int

    var cfRange: CFRange {
        CFRange(location: location, length: length)
    }
}

struct TextReplacementAnchor: Equatable {
    let targetPID: pid_t
    let bundleID: String
    let focusedElementIdentity: FocusedElementSignature.StableIdentity
    let sourceRange: AXTextRange?
    let boundaryUTF16Length: Int
    let caretAfterBoundary: Int?
    let expectedSource: String
    let allowsKeyboardFallback: Bool

    /// Whether the anchor may still be used after the user typed past it.
    ///
    /// A keyboard-fallback anchor deletes blind at the *current* caret. In an editor
    /// that exposes no caret (Chrome, web fields) nothing can prove the caret has not
    /// moved, so once the user has typed on, those deletes would eat the new text.
    var survivesLaterTyping: Bool {
        !allowsKeyboardFallback
    }

    static func sourceRange(
        caretAfterBoundary: Int,
        source: String,
        boundary: String
    ) -> AXTextRange? {
        let sourceLength = source.utf16.count
        let boundaryLength = boundary.utf16.count
        let location = caretAfterBoundary - boundaryLength - sourceLength
        guard sourceLength > 0, boundaryLength > 0, location >= 0 else { return nil }
        return AXTextRange(location: location, length: sourceLength)
    }
}

struct TextReplacementResult: Equatable {
    /// Nil only when the editor committed the replacement but did not confirm the requested
    /// collapsed caret, so a later undo/retry cannot be anchored safely.
    let recoveryAnchor: TextReplacementAnchor?
}

struct KeyboardFallbackPlan: Equatable {
    let deleteCount: Int
    let replacement: String
}

struct FocusedElementSignature: Equatable {
    let pid: pid_t
    let role: String?
    let subrole: String?
    let windowTitleHash: Int?
    let elementIdentifier: String?
    let frameHash: Int?
    let selectedRangeLocation: Int?
    let elementIdentity: AXUIElement?

    init(
        pid: pid_t,
        role: String?,
        subrole: String?,
        windowTitleHash: Int?,
        elementIdentifier: String?,
        frameHash: Int?,
        selectedRangeLocation: Int?,
        elementIdentity: AXUIElement? = nil
    ) {
        self.pid = pid
        self.role = role
        self.subrole = subrole
        self.windowTitleHash = windowTitleHash
        self.elementIdentifier = elementIdentifier
        self.frameHash = frameHash
        self.selectedRangeLocation = selectedRangeLocation
        self.elementIdentity = elementIdentity
    }

    var stableIdentity: StableIdentity {
        StableIdentity(
            pid: pid,
            role: role,
            subrole: subrole,
            windowTitleHash: windowTitleHash,
            elementIdentifier: elementIdentifier,
            frameHash: frameHash
        )
    }

    func matchesTypingTarget(
        _ other: FocusedElementSignature,
        expectedCaretAdvance: Int
    ) -> Bool {
        guard pid == other.pid,
              role == other.role,
              subrole == other.subrole
        else {
            return false
        }

        if let elementIdentifier,
           let otherIdentifier = other.elementIdentifier,
           elementIdentifier != otherIdentifier {
            return false
        }

        // Deliberate early return: when both signatures expose a caret, caret
        // arithmetic alone decides, *before* windowTitleHash / frameHash /
        // stableIdentity are consulted. This reads like a missing identity
        // check, and it is not — those fields are unstable in exactly the
        // editors that do expose a caret. Browser tabs retitle while you type,
        // documents gain an "edited" marker, and chat composers grow and
        // scroll, all of which change the identity mid-word and would drop a
        // correction the user was mid-way through earning.
        //
        // The residual risk is a same-role sibling field whose caret happens to
        // land on start + expectedCaretAdvance. `captureReplacementAnchor`
        // catches that by reading the text back before mutating, so this
        // shortcut is only load-bearing where the readback also fails.
        // Pinned by AutoFixTargetValidatorTests
        // .allowsDynamicGeometryWithoutIdentifierWhenCaretMatches.
        if let selectedRangeLocation,
           let otherLocation = other.selectedRangeLocation {
            return otherLocation == selectedRangeLocation + expectedCaretAdvance
        }

        if let elementIdentity,
           let otherIdentity = other.elementIdentity,
           elementIdentity != otherIdentity,
           (frameHash == nil || frameHash != other.frameHash) {
            return false
        }

        return stableIdentity == other.stableIdentity
    }

    /// First signature component that differs from `other`, for the skip log.
    func mismatchDetail(_ other: FocusedElementSignature) -> String {
        if pid != other.pid { return "pid" }
        if role != other.role { return "role" }
        if subrole != other.subrole { return "subrole" }
        if let elementIdentifier, let otherIdentifier = other.elementIdentifier,
           elementIdentifier != otherIdentifier { return "identifier" }
        if selectedRangeLocation != nil, other.selectedRangeLocation != nil { return "caret" }
        if (selectedRangeLocation == nil) != (other.selectedRangeLocation == nil) { return "caret_availability" }
        if windowTitleHash != other.windowTitleHash { return "window_title" }
        if frameHash != other.frameHash { return "frame" }
        return "element"
    }

    /// Identity check that deliberately ignores caret position and window geometry.
    ///
    /// Used when the caret an anchor refers to was recorded earlier, at the word
    /// boundary, and the live caret has legitimately moved on because the user kept
    /// typing. Position can no longer corroborate identity — demanding it is what
    /// made every fast typist's correction fail — so the anchor is proved instead by
    /// reading the expected text back at the recorded range.
    ///
    /// windowTitleHash and frameHash are excluded on purpose: they drift while you
    /// type (tab titles, growing composers) and were never evidence of identity.
    func matchesTypingTargetIgnoringPosition(_ other: FocusedElementSignature) -> Bool {
        guard pid == other.pid,
              role == other.role,
              subrole == other.subrole
        else {
            return false
        }
        if let elementIdentifier,
           let otherIdentifier = other.elementIdentifier,
           elementIdentifier != otherIdentifier {
            return false
        }
        return true
    }

    struct StableIdentity: Equatable {
        let pid: pid_t
        let role: String?
        let subrole: String?
        let windowTitleHash: Int?
        let elementIdentifier: String?
        let frameHash: Int?
    }
}

struct AutoFixTargetSession: Equatable {
    let tokenID: UUID
    let startedAt: TimeInterval
    let targetPID: pid_t?
    let bundleID: String?
    let appName: String?
    let focusedElementSignature: FocusedElementSignature?
    let firstKeyCode: UInt16
    let firstCharacter: String
}

enum AutoFixTargetValidation: Equatable {
    case verified
    case changed(String)
    case unverifiable(String)

    var canMutate: Bool {
        self == .verified
    }

    var skipReason: AutoFixSkipReason {
        switch self {
        case .verified:
            return .targetUnverifiable
        case .changed:
            return .targetChanged
        case .unverifiable:
            return .targetUnverifiable
        }
    }
}

@MainActor
final class AutoFixTargetValidator {
    private(set) var session: AutoFixTargetSession?

    /// Which AX read stopped the last `captureReplacementAnchor` from producing an
    /// anchor. Carried purely so the skip event can name the failing step — the
    /// controller used to log a bare `target_unverifiable` that covered four
    /// different causes and made this class undiagnosable from the field logs.
    private(set) var lastFailureReason: String?

    struct CaretMismatch: Equatable {
        let expected: [Int]
        let actual: Int
    }

    /// How far the caret actually moved versus what was acceptable, recorded whenever
    /// a caret comparison rejects the target. Logged so a future regression here is a
    /// number to read rather than a theory to guess at — the previous three attempts
    /// at this bug were guesses.
    private(set) var lastCaretMismatch: CaretMismatch?
    /// Which part of the focused-element signature differed on the last
    /// `focused_element_changed` verdict. Diagnostics only.
    private(set) var lastTargetMismatchDetail: String?

    /// The live collapsed caret, for callers that need to record it while it is still
    /// fresh — i.e. at the word boundary, before any grace period lets it drift.
    func currentCaretLocation() -> Int? {
        guard let focused = Self.focusedElement(),
              let selection = Self.selectedTextRange(for: focused),
              selection.length == 0
        else {
            return nil
        }
        return selection.location
    }

    /// How many times a focused-element read is re-sampled before giving up.
    ///
    /// Apps move focus between their own elements between words — Telegram flips
    /// between the composer's `AXTextArea` and the message list's `AXStaticText`,
    /// and the system-wide read returns nil outright now and then. Sampling once
    /// turns those moments into a dropped correction.
    ///
    /// Note what this is *not* for: during steady typing the AX caret is healthy and
    /// monotonic even in Electron apps. An earlier reading of this code blamed
    /// "oscillation while typing" for the mass failures; the real cause was caret
    /// arithmetic (see `acceptableCaretAdvances` and `restoredCaretLocation`).
    /// Re-sampling changes only how many chances we take — never what counts as
    /// acceptable, which is still an exact readback of `source + boundary` at the
    /// range we are about to mutate.
    private static let focusSampleAttempts = 3
    private static let focusSampleRetryDelay: TimeInterval = 0.008

    func reset() {
        session = nil
        lastFailureReason = nil
    }

    @discardableResult
    func startSession(event: CGEvent, keyCode: UInt16, typedString: String) -> AutoFixTargetSession {
        startSession(
            targetPID: Self.targetPID(from: event),
            keyCode: keyCode,
            typedString: typedString
        )
    }

    @discardableResult
    func startSession(targetPID: pid_t?, keyCode: UInt16, typedString: String) -> AutoFixTargetSession {
        let app = NSWorkspace.shared.frontmostApplication
        let session = AutoFixTargetSession(
            tokenID: UUID(),
            startedAt: ProcessInfo.processInfo.systemUptime,
            targetPID: targetPID,
            bundleID: app?.bundleIdentifier,
            appName: app?.localizedName,
            // Re-sampled like every other focused-element read here. This one fires on
            // the first keystroke of a word, and a nil captured here poisons the word:
            // validateCurrentTarget can only answer `missing_initial_focused_element`
            // from then on, no matter how healthy the AX tree becomes by the boundary.
            focusedElementSignature: Self.resampledFocusedElementSignature(),
            firstKeyCode: keyCode,
            firstCharacter: typedString
        )
        self.session = session
        return session
    }

    func validateCurrentTarget(
        expectedBundleID: String?,
        source: String,
        boundary: String
    ) -> AutoFixTargetValidation {
        guard let session else {
            return .unverifiable("missing_session")
        }
        return validateCurrentTarget(
            for: session,
            expectedBundleID: expectedBundleID,
            source: source,
            boundary: boundary
        )
    }

    /// Caret advances that are both consistent with the user having typed `source`
    /// followed by `boundary` since the session started.
    ///
    /// The event tap is created with `.defaultTap`, so Papuga's callback runs *before*
    /// the keystroke reaches the target app, and `handleEvent` then hops to the main
    /// actor. Whether the app has inserted a character by the time we read its caret
    /// is therefore a race Papuga usually wins. `landed` assumes the session's first
    /// character was already in the field when the session caret was sampled;
    /// `pending` assumes it was not. Guessing one of them was the original bug: every
    /// caret-exposing app (Telegram, Notes, Teams) reported `focused_element_changed`
    /// forever while caret-less ones (Warp, Chrome) worked fine.
    nonisolated static func acceptableCaretAdvances(
        source: String,
        boundary: String,
        firstCharacter: String
    ) -> [Int] {
        let landed = max(0, source.utf16.count - firstCharacter.utf16.count) + boundary.utf16.count
        let pending = source.utf16.count + boundary.utf16.count
        return landed == pending ? [landed] : [landed, pending]
    }

    /// - Parameter knownBoundaryCaret: the caret recorded at the word boundary, when
    ///   the caller already has one. Its presence means the live caret is expected to
    ///   have moved on — the user kept typing during the grace period — so caret
    ///   arithmetic is skipped and identity is checked without position.
    func validateCurrentTarget(
        for session: AutoFixTargetSession,
        expectedBundleID: String? = nil,
        source: String,
        boundary: String,
        knownBoundaryCaret: Int? = nil
    ) -> AutoFixTargetValidation {
        lastTargetMismatchDetail = nil
        let activeBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let expected = expectedBundleID?.nilIfEmpty ?? session.bundleID?.nilIfEmpty

        if let expected, let activeBundleID, activeBundleID != expected {
            return .changed("bundle_changed")
        }

        guard let originalSignature = session.focusedElementSignature else {
            return .unverifiable("missing_initial_focused_element")
        }

        let advances = Self.acceptableCaretAdvances(
            source: source,
            boundary: boundary,
            firstCharacter: session.firstCharacter
        )

        // "Any sample matches", not "the first sample matches". Consecutive reads can
        // disagree while an app moves focus between its own elements between words, and
        // a target that genuinely moved still fails every sample. Nothing is mutated on
        // the strength of this verdict alone: captureReplacementAnchor still has to read
        // `source + boundary` back, and replaceAnchoredText still has to confirm the
        // commit.
        var sawCurrentSignature = false
        for attempt in 0..<Self.focusSampleAttempts {
            if attempt > 0 {
                Thread.sleep(forTimeInterval: Self.focusSampleRetryDelay)
            }
            guard let currentSignature = Self.focusedElementSignature() else { continue }
            sawCurrentSignature = true

            if knownBoundaryCaret != nil {
                if originalSignature.matchesTypingTargetIgnoringPosition(currentSignature) {
                    lastCaretMismatch = nil
                    return .verified
                }
                continue
            }

            if advances.contains(where: {
                originalSignature.matchesTypingTarget(currentSignature, expectedCaretAdvance: $0)
            }) {
                lastCaretMismatch = nil
                return .verified
            }

            if let original = originalSignature.selectedRangeLocation,
               let current = currentSignature.selectedRangeLocation {
                lastCaretMismatch = CaretMismatch(expected: advances, actual: current - original)
            }
        }

        guard sawCurrentSignature else {
            return .unverifiable("missing_current_focused_element")
        }
        // Web and Electron composers re-create their accessibility proxy, grow,
        // and retitle their window mid-word, so identity and caret arithmetic
        // both drift while the user never left the field. The text is the
        // stronger witness: same process, role and identifier, and the typed
        // token readable right where it should be. captureReplacementAnchor
        // repeats that readback before anything is mutated.
        if let focused = Self.focusedElement(),
           let signature = Self.focusedElementSignature(for: focused) {
            lastTargetMismatchDetail = originalSignature.mismatchDetail(signature)
            if originalSignature.matchesTypingTargetIgnoringPosition(signature),
               Self.typedTokenIsReadable(source: source, boundary: boundary, in: focused) {
                lastCaretMismatch = nil
                lastTargetMismatchDetail = nil
                return .verified
            }
        }
        return .changed("focused_element_changed")
    }

    /// The typed token read back from the element itself: ending at a collapsed
    /// caret, or — when no caret is exposed — as the tail of the value.
    private static func typedTokenIsReadable(source: String, boundary: String, in element: AXUIElement) -> Bool {
        let expected = readbackBoundaries(boundary).map { source + $0 }
        let length = source.utf16.count + boundary.utf16.count
        if let selection = selectedTextRange(for: element) {
            guard selection.length == 0, selection.location >= length else { return false }
            let range = AXTextRange(location: selection.location - length, length: length)
            return string(for: range, in: element).map(expected.contains) ?? false
        }
        guard let value = stringAttribute(kAXValueAttribute as CFString, from: element) else { return false }
        return valueSuffixRange(source: source, boundary: boundary, in: value) != nil
    }

    func validateKeyEventStillTargetsSession(_ event: CGEvent) -> AutoFixTargetValidation {
        validateKeyEventStillTargetsSession(targetPID: Self.targetPID(from: event))
    }

    func validateKeyEventStillTargetsSession(targetPID: pid_t?) -> AutoFixTargetValidation {
        guard let session else {
            return .unverifiable("missing_session")
        }

        if let originalPID = session.targetPID,
           let currentPID = targetPID,
           originalPID != currentPID {
            return .changed("event_target_pid_changed")
        }

        // Cheap per-keystroke check only: the event still targets the same process (or the target
        // PID is unavailable). Deliberately do NOT run the full focused-element AX signature here —
        // that is 7-9 synchronous AX IPC round-trips, and on this path it would fire on every
        // non-boundary keystroke. The expensive comparison is deferred to the word boundary
        // (validateCurrentTarget in evaluateAndMaybeFix) and to mutationIsStillSafe, which run
        // immediately before any mutation, so an undetected mid-word focus change can at worst skip
        // a fix — never apply a wrong one.
        return .verified
    }

    /// Pins the just-typed token to an exact AX range, re-sampling the focused
    /// element as described on `focusSampleAttempts`.
    ///
    /// Two ways to reach a verified range, tried in that order per sample:
    /// the caret, and — when the caret is unusable — the tail of the element's
    /// `AXValue`. Both end at the same acceptance test, an exact readback of
    /// `source + boundary`, so a bad sample costs a retry rather than a wrong edit.
    func captureReplacementAnchor(
        for session: AutoFixTargetSession,
        expectedBundleID: String,
        source: String,
        boundary: String,
        boundaryCaret: Int? = nil,
        allowsKeyboardFallback: Bool = true
    ) -> TextReplacementAnchor? {
        lastFailureReason = nil
        let validation = validateCurrentTarget(
            for: session,
            expectedBundleID: expectedBundleID,
            source: source,
            boundary: boundary,
            knownBoundaryCaret: boundaryCaret
        )
        guard validation == .verified else {
            switch validation {
            case .verified:
                break
            case .changed(let reason), .unverifiable(let reason):
                lastFailureReason = reason
            }
            return nil
        }

        func makeAnchor(
            signature: FocusedElementSignature,
            sourceRange: AXTextRange?,
            caretAfterBoundary: Int?,
            allowsKeyboardFallback: Bool
        ) -> TextReplacementAnchor {
            TextReplacementAnchor(
                targetPID: signature.pid,
                bundleID: expectedBundleID,
                focusedElementIdentity: signature.stableIdentity,
                sourceRange: sourceRange,
                boundaryUTF16Length: boundary.utf16.count,
                caretAfterBoundary: caretAfterBoundary,
                expectedSource: source,
                allowsKeyboardFallback: allowsKeyboardFallback
            )
        }

        // The unverified keyboard fallback is the weakest path in the app — it
        // deletes blind and offers no undo. A verified anchor from a *later*
        // sample must therefore beat a fallback offered by an earlier one, so hold
        // the fallback aside instead of returning on the first sample that allows
        // it. Before re-sampling existed this ordering could not arise.
        var fallbackAnchor: TextReplacementAnchor?
        var failure = "missing_focused_element"

        for attempt in 0..<Self.focusSampleAttempts {
            if attempt > 0 {
                Thread.sleep(forTimeInterval: Self.focusSampleRetryDelay)
            }

            // Same element test validateCurrentTarget just passed — a pid match
            // alone would let a sibling field holding the same text be anchored.
            guard let focused = Self.focusedElement(),
                  let signature = Self.focusedElementSignature(for: focused),
                  session.focusedElementSignature?.matchesTypingTargetIgnoringPosition(signature) == true
            else {
                continue
            }

            let selection = Self.selectedTextRange(for: focused)
            // The caret recorded at the boundary wins over the live one whenever the
            // caller kept it. By mutation time the user has usually typed several more
            // characters, so the live caret no longer sits after the token — but the
            // token itself has not moved, and the readback below still proves it.
            let anchorCaret = boundaryCaret ?? selection.flatMap { $0.length == 0 ? $0.location : nil }
            let caretRange: AXTextRange? = anchorCaret.flatMap { caret in
                TextReplacementAnchor.sourceRange(
                    caretAfterBoundary: caret,
                    source: source,
                    boundary: boundary
                )
            }

            if let caretRange, Self.waitForReadableAnchor(
                source: source,
                boundary: boundary,
                sourceRange: caretRange,
                // The first sample keeps the original budget so a slow web editor
                // still gets the same time to publish its text (e93324d); later
                // samples are cheaper because the outer loop already waited.
                attempts: attempt == 0 ? 5 : 2,
                retryDelay: { Thread.sleep(forTimeInterval: 0.005) },
                readString: { Self.string(for: $0, in: focused) }
            ) {
                return makeAnchor(
                    signature: signature,
                    sourceRange: caretRange,
                    caretAfterBoundary: anchorCaret,
                    allowsKeyboardFallback: false
                )
            }

            // The token is still the tail of AXValue, so recover the range from the
            // text when the caret cannot describe it. The suffix match is its own
            // proof that nothing was typed past the boundary — so this path is
            // open even when a recorded caret exists but its readback failed
            // (Telegram flips focus mid-read and the caret sample dies while the
            // text sits right there).
            if selection?.length ?? 0 == 0,
               let suffix = Self.verifiedValueSuffixRange(
                source: source,
                boundary: boundary,
                in: focused
               ) {
                return makeAnchor(
                    signature: signature,
                    sourceRange: suffix.sourceRange,
                    caretAfterBoundary: suffix.caretAfterBoundary,
                    allowsKeyboardFallback: false
                )
            }

            // The blind fallback types at wherever the caret *currently* is, so it is
            // only meaningful while that is still the boundary. Once the user has typed
            // past it, backspacing would eat the word they are writing right now.
            let caretStillAtBoundary = boundaryCaret == nil || boundaryCaret == selection?.location
            if allowsKeyboardFallback, fallbackAnchor == nil, caretStillAtBoundary, Self.canUseKeyboardFallback(
                boundary: boundary,
                selection: selection,
                sourceRange: caretRange
            ) {
                fallbackAnchor = makeAnchor(
                    signature: signature,
                    sourceRange: caretRange,
                    caretAfterBoundary: selection?.location,
                    allowsKeyboardFallback: true
                )
            }

            failure = caretRange == nil ? "caret_outside_typed_token" : "editor_text_readback_failed"
        }

        if fallbackAnchor == nil {
            lastFailureReason = failure
        }
        return fallbackAnchor
    }

    /// Which step stopped the last `replaceAnchoredText`. One opaque
    /// `editor_content_mismatch` used to cover four different causes — Telegram's
    /// 7-of-7 failures were undiagnosable from field logs.
    private(set) var lastReplaceFailureReason: String?

    /// Uses the exact anchored range when available. Web editors without AX text readback may use
    /// the verified keyboard fallback, but only for an ordinary space boundary.
    func replaceAnchoredText(_ anchor: TextReplacementAnchor, with replacement: String) -> TextReplacementResult? {
        lastReplaceFailureReason = nil
        guard let sourceRange = anchor.sourceRange,
              let caretAfterBoundary = anchor.caretAfterBoundary,
              let focused = validatedElement(for: anchor)
        else {
            guard anchor.allowsKeyboardFallback,
                  validatedTarget(for: anchor, allowsStaleCaret: false) != nil,
                  let plan = Self.keyboardFallbackPlan(
                    source: anchor.expectedSource,
                    boundary: " ",
                    replacement: replacement
                  ),
                  Self.postKeyboardFallback(plan)
            else {
                lastReplaceFailureReason = "anchor_invalid"
                return nil
            }
            return TextReplacementResult(recoveryAnchor: nil)
        }

        // Where the user actually is, read before anything moves. By the time a fix
        // lands they are usually a word or two further on, and putting the caret back
        // beside the corrected token would yank them backwards mid-sentence.
        let liveCaretBeforeEdit = Self.selectedTextRange(for: focused)
            .flatMap { $0.length == 0 ? $0.location : nil }

        guard Self.isAttributeSettable(kAXSelectedTextRangeAttribute as CFString, on: focused) else {
            lastReplaceFailureReason = "selection_not_settable"
            return nil
        }
        guard Self.setSelectedTextRange(sourceRange, on: focused) else {
            lastReplaceFailureReason = "selection_set_failed"
            return nil
        }

        // Qt editors (Telegram Desktop) expose a settable selection range but no
        // settable AXSelectedText. Demanding both attributes killed the write
        // before the Unicode-events path below ever got a chance — the verified
        // selection is all that path actually needs.
        let canWriteSelectedText = Self.isAttributeSettable(kAXSelectedTextAttribute as CFString, on: focused)
        let axWriteSucceeded = canWriteSelectedText && AXUIElementSetAttributeValue(
            focused,
            kAXSelectedTextAttribute as CFString,
            replacement as CFTypeRef
        ) == .success

        let replacementLength = replacement.utf16.count
        let replacementRange = AXTextRange(
            location: sourceRange.location,
            length: replacementLength
        )
        var replacementCommitted = axWriteSucceeded && Self.waitForCommittedReplacement(
            expected: replacement,
            at: replacementRange,
            attempts: 3,
            retryDelay: { Thread.sleep(forTimeInterval: 0.005) },
            readString: { Self.string(for: $0, in: focused) }
        )

        // Chromium-backed editors such as Cursor can report AXSelectedText success while ignoring
        // the write. The exact source range is already validated, so replace that selection with
        // tagged Unicode events and confirm the resulting text before reporting success.
        if !replacementCommitted,
           Self.string(for: sourceRange, in: focused) == anchor.expectedSource,
           Self.setSelectedTextRange(sourceRange, on: focused),
           // The events go to whatever holds keyboard focus, so re-check focus and
           // selection right before posting. This narrows the window; it cannot close it.
           Self.selectionStillTargets(anchor: anchor, element: focused, range: sourceRange),
           Self.postUnicodeReplacement(replacement) {
            replacementCommitted = Self.waitForCommittedReplacement(
                expected: replacement,
                at: replacementRange,
                attempts: 10,
                retryDelay: { Thread.sleep(forTimeInterval: 0.005) },
                readString: { Self.string(for: $0, in: focused) }
            )
        }

        guard replacementCommitted else {
            _ = Self.setSelectedTextRange(
                AXTextRange(location: liveCaretBeforeEdit ?? caretAfterBoundary, length: 0),
                on: focused
            )
            lastReplaceFailureReason = canWriteSelectedText
                ? "write_not_committed"
                : "unicode_fallback_not_committed"
            return nil
        }

        let resultingCaret = Self.restoredCaretLocation(
            liveCaret: liveCaretBeforeEdit,
            sourceRange: sourceRange,
            replacementUTF16Length: replacementLength,
            boundaryUTF16Length: anchor.boundaryUTF16Length
        )
        _ = Self.setSelectedTextRange(
            AXTextRange(location: resultingCaret, length: 0),
            on: focused
        )
        // Read back the actual selection instead of assuming how an editor behaves after setting
        // AXSelectedText. A non-collapsed/unknown selection cannot produce a safe recovery anchor.
        guard let resultingSelection = Self.selectedTextRange(for: focused),
              resultingSelection == AXTextRange(location: resultingCaret, length: 0)
        else {
            return TextReplacementResult(recoveryAnchor: nil)
        }

        return TextReplacementResult(
            recoveryAnchor: TextReplacementAnchor(
                targetPID: anchor.targetPID,
                bundleID: anchor.bundleID,
                focusedElementIdentity: anchor.focusedElementIdentity,
                sourceRange: AXTextRange(location: sourceRange.location, length: replacementLength),
                boundaryUTF16Length: anchor.boundaryUTF16Length,
                caretAfterBoundary: resultingSelection.location,
                expectedSource: replacement,
                allowsKeyboardFallback: false
            )
        )
    }

    /// Where to leave the caret after a replacement.
    ///
    /// A fix lands up to `singleWordGrace` (0.3 s) — or `incidentIdleDelay` (0.6 s) for
    /// a sentence — after the boundary that triggered it, and a typist covers several
    /// characters in that time. Whatever text sits after the corrected token is the
    /// word they are writing *now*, so the caret has to come back to where they left
    /// it, shifted only by how much the token grew or shrank.
    ///
    /// The old behaviour — parking the caret just past the corrected token — is kept
    /// for the case it was written for: no readable live caret, or a caret that had not
    /// moved past the token at all.
    nonisolated static func restoredCaretLocation(
        liveCaret: Int?,
        sourceRange: AXTextRange,
        replacementUTF16Length: Int,
        boundaryUTF16Length: Int
    ) -> Int {
        let tokenEnd = sourceRange.location + sourceRange.length
        guard let liveCaret, liveCaret >= tokenEnd else {
            return sourceRange.location + replacementUTF16Length + boundaryUTF16Length
        }
        return liveCaret + (replacementUTF16Length - sourceRange.length)
    }

    /// Largest token this path will blind-delete.
    ///
    /// The fallback fires Delete keystrokes without being able to read the
    /// field back, so the count is asserted, not verified. A single typed token
    /// between whitespace boundaries is short; anything long means the anchor's
    /// `expectedSource` no longer describes reality, and the safe answer is to
    /// do nothing rather than eat an unknown amount of the user's text.
    nonisolated static let maxUnverifiedDeleteCharacters = 48

    nonisolated static func keyboardFallbackPlan(
        source: String,
        boundary: String,
        replacement: String
    ) -> KeyboardFallbackPlan? {
        guard boundary == " " else { return nil }
        // Deleting nothing then typing a replacement would duplicate text.
        guard !source.isEmpty, !replacement.isEmpty else { return nil }
        guard source.count <= maxUnverifiedDeleteCharacters else { return nil }
        return KeyboardFallbackPlan(
            // Grapheme count, deliberately — unlike every AX range in this file,
            // which is UTF-16. One Delete keypress removes one user-perceived
            // character, so an emoji (2 UTF-16 units) still takes one press.
            // Counting UTF-16 here would over-delete.
            deleteCount: source.count + 1,
            replacement: replacement + boundary
        )
    }

    /// `selection == nil` means the editor exposes no AX text range at all —
    /// Chrome and similar web editors. That case is allowed on purpose (see
    /// e93324d); refusing it would remove AutoFix from web fields entirely.
    ///
    /// It is the weakest guarantee in the app: the replacement is posted blind
    /// and, because `replaceAnchoredText` returns no recovery anchor for it,
    /// **no undo is offered** — precisely where the mutation is least verified.
    /// The delete count is bounded in `keyboardFallbackPlan` so the blast
    /// radius is at least fixed.
    nonisolated static func canUseKeyboardFallback(
        boundary: String,
        selection: AXTextRange?,
        sourceRange: AXTextRange?
    ) -> Bool {
        guard boundary == " " else { return false }
        // A non-collapsed selection means the user has text selected; deleting
        // backwards from there would destroy it.
        guard let selection else { return true }
        return selection.length == 0 && sourceRange != nil
    }

    nonisolated static func replacementWasCommitted(
        expected: String,
        at range: AXTextRange,
        readString: (AXTextRange) -> String?
    ) -> Bool {
        readString(range) == expected
    }

    nonisolated static func waitForCommittedReplacement(
        expected: String,
        at range: AXTextRange,
        attempts: Int,
        retryDelay: () -> Void,
        readString: (AXTextRange) -> String?
    ) -> Bool {
        guard attempts > 0 else { return false }
        for attempt in 0..<attempts {
            if replacementWasCommitted(expected: expected, at: range, readString: readString) {
                return true
            }
            if attempt < attempts - 1 {
                retryDelay()
            }
        }
        return false
    }

    /// The boundary as the editor stores it, versus as the key event reported it.
    ///
    /// `keyboardGetUnicodeString` reports Return as U+000D; AX text on macOS holds U+000A.
    /// Both are one UTF-16 unit, so no range arithmetic changes — only the readback
    /// comparison has to accept either. Without this, every Enter-terminated fix died as
    /// `target_unverifiable`, and since `keyboardFallbackPlan` refuses any boundary but a
    /// space, there was no second chance.
    nonisolated static func readbackBoundaries(_ boundary: String) -> [String] {
        boundary == "\r" ? ["\n", "\r"] : [boundary]
    }

    nonisolated static func waitForReadableAnchor(
        source: String,
        boundary: String,
        sourceRange: AXTextRange,
        attempts: Int,
        retryDelay: () -> Void,
        readString: (AXTextRange) -> String?
    ) -> Bool {
        guard attempts > 0 else { return false }
        let expected = readbackBoundaries(boundary).map { source + $0 }
        let range = AXTextRange(
            location: sourceRange.location,
            length: sourceRange.length + boundary.utf16.count
        )
        for attempt in 0..<attempts {
            // Both renderings are tried inside one attempt: which one an editor uses is
            // fixed, so alternating between retries would only halve the budget.
            if let text = readString(range), expected.contains(text) {
                return true
            }
            if attempt < attempts - 1 {
                retryDelay()
            }
        }
        return false
    }

    private static func postUnicodeReplacement(_ replacement: String) -> Bool {
        let source = CGEventSource(stateID: .hidSystemState)
        guard let keyDown = CGEvent(
            keyboardEventSource: source,
            virtualKey: 0,
            keyDown: true
        ), let keyUp = CGEvent(
            keyboardEventSource: source,
            virtualKey: 0,
            keyDown: false
        ) else {
            return false
        }

        let utf16 = Array(replacement.utf16)
        utf16.withUnsafeBufferPointer { buffer in
            keyDown.keyboardSetUnicodeString(
                stringLength: buffer.count,
                unicodeString: buffer.baseAddress
            )
            keyUp.keyboardSetUnicodeString(
                stringLength: buffer.count,
                unicodeString: buffer.baseAddress
            )
        }
        PapugaSyntheticEvent.tag(keyDown)
        PapugaSyntheticEvent.tag(keyUp)
        keyDown.post(tap: .cgAnnotatedSessionEventTap)
        keyUp.post(tap: .cgAnnotatedSessionEventTap)
        return true
    }

    private static func postKeyboardFallback(_ plan: KeyboardFallbackPlan) -> Bool {
        let source = CGEventSource(stateID: .hidSystemState)
        guard let deleteDown = CGEvent(
            keyboardEventSource: source,
            virtualKey: CGKeyCode(kVK_Delete),
            keyDown: true
        ), let deleteUp = CGEvent(
            keyboardEventSource: source,
            virtualKey: CGKeyCode(kVK_Delete),
            keyDown: false
        ), let replacementDown = CGEvent(
            keyboardEventSource: source,
            virtualKey: 0,
            keyDown: true
        ), let replacementUp = CGEvent(
            keyboardEventSource: source,
            virtualKey: 0,
            keyDown: false
        ) else {
            return false
        }

        let utf16 = Array(plan.replacement.utf16)
        utf16.withUnsafeBufferPointer { buffer in
            replacementDown.keyboardSetUnicodeString(
                stringLength: buffer.count,
                unicodeString: buffer.baseAddress
            )
            replacementUp.keyboardSetUnicodeString(
                stringLength: buffer.count,
                unicodeString: buffer.baseAddress
            )
        }
        [deleteDown, deleteUp, replacementDown, replacementUp].forEach(PapugaSyntheticEvent.tag)
        for _ in 0..<plan.deleteCount {
            deleteDown.post(tap: .cgAnnotatedSessionEventTap)
            deleteUp.post(tap: .cgAnnotatedSessionEventTap)
        }
        replacementDown.post(tap: .cgAnnotatedSessionEventTap)
        replacementUp.post(tap: .cgAnnotatedSessionEventTap)
        return true
    }

    func isReplacementAnchorValid(_ anchor: TextReplacementAnchor) -> Bool {
        validatedElement(for: anchor) != nil
            || (anchor.allowsKeyboardFallback
                && validatedTarget(for: anchor, allowsStaleCaret: false) != nil)
    }

    private func validatedElement(for anchor: TextReplacementAnchor) -> AXUIElement? {
        guard let sourceRange = anchor.sourceRange,
              let focused = validatedTarget(for: anchor, allowsStaleCaret: true),
              Self.string(for: sourceRange, in: focused) == anchor.expectedSource
        else {
            return nil
        }
        return focused
    }

    /// Whether the caret must still sit exactly where the anchor recorded it.
    ///
    /// Reading `expectedSource` back at an exact range is strictly stronger evidence than
    /// caret position, so a caller that does that readback does not need a frozen caret —
    /// demanding one is what broke every correction for anyone who kept typing through the
    /// grace period.
    ///
    /// The blind keyboard path reads nothing back: it fires Delete at wherever the caret
    /// happens to be. There the caret is the only anchor there is, so it must be frozen —
    /// even though such an anchor may also carry a `sourceRange` that its own path never uses.
    nonisolated static func requiresFrozenCaret(
        anchor: TextReplacementAnchor,
        allowsStaleCaret: Bool
    ) -> Bool {
        !(allowsStaleCaret && anchor.sourceRange != nil)
    }

    /// Re-checks, immediately before mutating, that the anchor still describes the
    /// element and caret it was captured against.
    ///
    /// Re-sampled for the same reason `captureReplacementAnchor` is: a single read
    /// here would throw away an anchor that was just verified a few milliseconds
    /// earlier, turning a correct fix into `replacement_not_committed`.
    private func validatedTarget(
        for anchor: TextReplacementAnchor,
        allowsStaleCaret: Bool
    ) -> AXUIElement? {
        for attempt in 0..<Self.focusSampleAttempts {
            if attempt > 0 {
                Thread.sleep(forTimeInterval: Self.focusSampleRetryDelay)
            }

            guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == anchor.bundleID,
                  let focused = Self.focusedElement(),
                  let signature = Self.focusedElementSignature(for: focused),
                  signature.pid == anchor.targetPID,
                  signature.stableIdentity == anchor.focusedElementIdentity
            else {
                continue
            }

            if !Self.requiresFrozenCaret(anchor: anchor, allowsStaleCaret: allowsStaleCaret) {
                return focused
            }

            let selection = Self.selectedTextRange(for: focused)
            if let caretAfterBoundary = anchor.caretAfterBoundary {
                guard selection == AXTextRange(location: caretAfterBoundary, length: 0) else { continue }
            } else {
                guard selection == nil else { continue }
            }
            return focused
        }
        return nil
    }

    nonisolated static func targetPID(from event: CGEvent) -> pid_t? {
        let raw = event.getIntegerValueField(.eventTargetUnixProcessID)
        guard raw > 0 else { return nil }
        return pid_t(raw)
    }

    static func focusedElementSignature() -> FocusedElementSignature? {
        guard let focused = focusedElement() else { return nil }
        return focusedElementSignature(for: focused)
    }

    private static func focusedElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedRef
        ) == .success,
              let focusedRef,
              CFGetTypeID(focusedRef) == AXUIElementGetTypeID()
        else {
            return nil
        }

        return unsafeBitCast(focusedRef, to: AXUIElement.self)
    }

    private static func focusedElementSignature(for focused: AXUIElement) -> FocusedElementSignature? {
        var pid: pid_t = 0
        guard AXUIElementGetPid(focused, &pid) == .success else {
            return nil
        }

        return FocusedElementSignature(
            pid: pid,
            role: stringAttribute(kAXRoleAttribute as CFString, from: focused),
            subrole: stringAttribute(kAXSubroleAttribute as CFString, from: focused),
            windowTitleHash: windowTitleHash(for: focused),
            elementIdentifier: stringAttribute("AXIdentifier" as CFString, from: focused),
            frameHash: frameHash(for: focused),
            selectedRangeLocation: selectedRangeLocation(for: focused),
            elementIdentity: focused
        )
    }

    private static func selectedTextRange(for element: AXUIElement) -> AXTextRange? {
        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &rangeRef
        ) == .success,
              let rangeRef,
              CFGetTypeID(rangeRef) == AXValueGetTypeID()
        else {
            return nil
        }

        let value = unsafeBitCast(rangeRef, to: AXValue.self)
        var range = CFRange()
        guard AXValueGetValue(value, .cfRange, &range) else { return nil }
        return AXTextRange(location: range.location, length: range.length)
    }

    private static func string(for range: AXTextRange, in element: AXUIElement) -> String? {
        var cfRange = range.cfRange
        guard let rangeValue = AXValueCreate(.cfRange, &cfRange) else { return nil }
        var result: CFTypeRef?
        if AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXStringForRangeParameterizedAttribute as CFString,
            rangeValue,
            &result
        ) == .success,
           let string = result as? String {
            return string
        }

        guard let value = stringAttribute(kAXValueAttribute as CFString, from: element) else {
            return nil
        }
        return substring(for: range, in: value)
    }

    nonisolated static func substring(for range: AXTextRange, in text: String) -> String? {
        let utf16 = text.utf16
        guard range.location >= 0,
              range.length >= 0,
              range.location <= utf16.count,
              range.length <= utf16.count - range.location else {
            return nil
        }
        let start = utf16.index(utf16.startIndex, offsetBy: range.location)
        let end = utf16.index(start, offsetBy: range.length)
        return String(decoding: utf16[start..<end], as: UTF16.self)
    }

    struct ValueSuffixAnchor: Equatable {
        let sourceRange: AXTextRange
        let caretAfterBoundary: Int
    }

    /// Range of `source` when `value` ends with exactly `source + boundary`.
    ///
    /// UTF-16 throughout, like every other AX range in this file. Requiring the
    /// token to sit at the very end of the field is what keeps this unambiguous —
    /// searching for it anywhere in the text could match an earlier occurrence of
    /// the same word and move the edit somewhere the user never typed.
    nonisolated static func valueSuffixRange(
        source: String,
        boundary: String,
        in value: String
    ) -> ValueSuffixAnchor? {
        let sourceLength = source.utf16.count
        let valueLength = value.utf16.count
        for needle in readbackBoundaries(boundary).map({ source + $0 }) {
            let needleLength = needle.utf16.count
            guard sourceLength > 0,
                  needleLength > sourceLength,
                  valueLength >= needleLength,
                  substring(
                    for: AXTextRange(location: valueLength - needleLength, length: needleLength),
                    in: value
                  ) == needle
            else {
                continue
            }
            return ValueSuffixAnchor(
                sourceRange: AXTextRange(location: valueLength - needleLength, length: sourceLength),
                caretAfterBoundary: valueLength
            )
        }
        return nil
    }

    /// `valueSuffixRange` confirmed through the *parameterized* AXStringForRange.
    ///
    /// Deriving a range from AXValue indices and then handing it to
    /// `setSelectedTextRange` assumes both speak the same coordinate space.
    /// AXStringForRange is what proves that assumption; `string(for:in:)` would
    /// not, because it falls back to slicing AXValue and would compare the value
    /// against itself. Editors that do not implement the parameterized attribute
    /// simply do not get this path.
    private static func verifiedValueSuffixRange(
        source: String,
        boundary: String,
        in element: AXUIElement
    ) -> ValueSuffixAnchor? {
        guard let value = stringAttribute(kAXValueAttribute as CFString, from: element),
              let anchor = valueSuffixRange(source: source, boundary: boundary, in: value),
              let confirmed = parameterizedString(
                for: AXTextRange(
                    location: anchor.sourceRange.location,
                    length: anchor.sourceRange.length + boundary.utf16.count
                ),
                in: element
              ),
              readbackBoundaries(boundary).map({ source + $0 }).contains(confirmed)
        else {
            return nil
        }
        return anchor
    }

    /// AXStringForRange with no AXValue fallback — see `verifiedValueSuffixRange`.
    private static func parameterizedString(for range: AXTextRange, in element: AXUIElement) -> String? {
        var cfRange = range.cfRange
        guard let rangeValue = AXValueCreate(.cfRange, &cfRange) else { return nil }
        var result: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXStringForRangeParameterizedAttribute as CFString,
            rangeValue,
            &result
        ) == .success else {
            return nil
        }
        return result as? String
    }

    /// Whether the word the user just finished typing provably stands alone in
    /// `value`: the field holds nothing but it, it opens the field, or it sits
    /// after whitespace at the very end. This is exactly the danger the
    /// conservative editing guard exists for — a word typed right after a click
    /// could be glued to pre-existing text ("к|" + "nj" → "кnj") — checked
    /// directly instead of assumed, so the first word of every fresh chat
    /// message stops being unfixable.
    nonisolated static func standsAloneInValue(
        source: String,
        boundary: String,
        value: String
    ) -> Bool {
        guard !source.isEmpty, !boundary.isEmpty else { return false }
        for rendered in readbackBoundaries(boundary) {
            let needle = source + rendered
            let starts = occurrenceStarts(of: needle, in: value)
            // Nothing says which copy the user just typed, so every copy must be
            // word-aligned: "nj щось кnj " opens with "nj " yet the typed one is glued.
            guard !starts.isEmpty,
                  starts.allSatisfy({ isWordStart(at: $0, in: value) })
            else { continue }
            if starts.contains(0) || starts.contains(value.utf16.count - needle.utf16.count) {
                return true
            }
        }
        return false
    }

    /// Whether a word can start at `location` (UTF-16): the field opens there or
    /// whitespace precedes it. An unreadable preceding unit answers false.
    nonisolated static func isWordStart(at location: Int, in value: String) -> Bool {
        guard location > 0 else { return true }
        guard let before = substring(for: AXTextRange(location: location - 1, length: 1), in: value),
              let scalar = before.unicodeScalars.first
        else { return false }
        return CharacterSet.whitespacesAndNewlines.contains(scalar)
    }

    /// The same claim proved from the caret instead of the field edge: the text
    /// ending at the caret is exactly the typed word, and that word starts at a
    /// word boundary. Covers what the edge rule cannot — a reply typed in the
    /// middle of a field, or a composer whose value ends in a stray newline.
    /// `source` alone (boundary not rendered yet) only counts when nothing but
    /// whitespace follows the caret.
    nonisolated static func standsAloneAtCaret(
        source: String,
        boundary: String,
        value: String,
        caret: Int
    ) -> Bool {
        guard !source.isEmpty, !boundary.isEmpty else { return false }
        let valueLength = value.utf16.count
        guard caret >= 0, caret <= valueLength else { return false }
        for needle in readbackBoundaries(boundary).map({ source + $0 }) + [source] {
            let length = needle.utf16.count
            let start = caret - length
            guard start >= 0,
                  substring(for: AXTextRange(location: start, length: length), in: value) == needle,
                  isWordStart(at: start, in: value)
            else { continue }
            if needle != source { return true }
            if caret == valueLength { return true }
            if let next = substring(for: AXTextRange(location: caret, length: 1), in: value)?.unicodeScalars.first,
               CharacterSet.whitespacesAndNewlines.contains(next) {
                return true
            }
        }
        return false
    }

    /// Why the typed word could not be proved to stand alone, or nil when it
    /// was. The reason goes to the skip log: `editing_context` alone could not
    /// tell an unreadable editor from a word genuinely glued to existing text.
    nonisolated static func standsAloneRejection(
        source: String,
        boundary: String,
        value: String,
        caret: Int?
    ) -> String? {
        if standsAloneInValue(source: source, boundary: boundary, value: value) { return nil }
        if let caret, standsAloneAtCaret(source: source, boundary: boundary, value: value, caret: caret) {
            return nil
        }
        let starts = occurrenceStarts(of: source, in: value)
        if starts.isEmpty { return "word_not_in_value" }
        if !starts.contains(where: { isWordStart(at: $0, in: value) }) { return "glued_to_text" }
        return caret == nil ? "not_at_edge_no_caret" : "not_at_edge"
    }

    /// `standsAloneRejection` against the live focused element, re-sampled as
    /// described on `focusSampleAttempts`. Unreadable field → rejected: when the
    /// claim cannot be proven, the editing guard stays in force.
    func typedWordStandsAloneRejection(source: String, boundary: String) -> String? {
        var rejection = "value_unreadable"
        for attempt in 0..<Self.focusSampleAttempts {
            if attempt > 0 {
                Thread.sleep(forTimeInterval: Self.focusSampleRetryDelay)
            }
            guard let focused = Self.focusedElement(),
                  let value = Self.stringAttribute(kAXValueAttribute as CFString, from: focused)
            else {
                continue
            }
            let selection = Self.selectedTextRange(for: focused)
            let caret = selection.flatMap { $0.length == 0 ? $0.location : nil }
            guard let reason = Self.standsAloneRejection(
                source: source, boundary: boundary, value: value, caret: caret
            ) else { return nil }
            rejection = reason
        }
        return rejection
    }

    /// Start of the *single* occurrence of `needle` in `value`, in UTF-16 units.
    /// Zero occurrences means the text is gone (the user fixed or sent it);
    /// more than one means the edit could land on text the user never typed —
    /// both answer nil, and the caller walks away without touching anything.
    nonisolated static func uniqueOccurrenceStart(of needle: String, in value: String) -> Int? {
        let starts = occurrenceStarts(of: needle, in: value)
        return starts.count == 1 ? starts[0] : nil
    }

    /// Every start of `needle` in `value`, in UTF-16 units, overlaps included.
    nonisolated static func occurrenceStarts(of needle: String, in value: String) -> [Int] {
        let haystack = Array(value.utf16)
        let target = Array(needle.utf16)
        guard !target.isEmpty, haystack.count >= target.count else { return [] }
        return (0...(haystack.count - target.count)).filter { start in
            !zip(haystack[start..<(start + target.count)], target).contains { $0 != $1 }
        }
    }

    /// Anchor for text typed a while ago — the deferred-chip path, where the
    /// user has kept typing since and no live session or caret describes the
    /// token anymore. The run is located by content instead: the single
    /// occurrence of `source + boundary` in the field, confirmed through the
    /// parameterized read so the range provably maps to what will be selected.
    /// No keyboard fallback — with nothing pinning the caret, a blind Delete
    /// burst could land anywhere.
    func captureRetroactiveAnchor(
        expectedBundleID: String,
        expectedIdentity: FocusedElementSignature.StableIdentity,
        source: String,
        boundary: String
    ) -> TextReplacementAnchor? {
        for attempt in 0..<Self.focusSampleAttempts {
            if attempt > 0 {
                Thread.sleep(forTimeInterval: Self.focusSampleRetryDelay)
            }
            guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == expectedBundleID,
                  let focused = Self.focusedElement(),
                  let signature = Self.focusedElementSignature(for: focused),
                  Self.isSameWindow(expectedIdentity, signature.stableIdentity),
                  let value = Self.stringAttribute(kAXValueAttribute as CFString, from: focused)
            else {
                continue
            }

            for rendered in Self.readbackBoundaries(boundary) {
                let needle = source + rendered
                // Word-aligned only: "nj " inside "xnj " is part of another word.
                guard let start = Self.uniqueOccurrenceStart(of: needle, in: value),
                      Self.isWordStart(at: start, in: value)
                else { continue }
                let sourceRange = AXTextRange(location: start, length: source.utf16.count)
                let confirmRange = AXTextRange(location: start, length: needle.utf16.count)
                guard Self.parameterizedString(for: confirmRange, in: focused) == needle else { continue }
                return TextReplacementAnchor(
                    targetPID: signature.pid,
                    bundleID: expectedBundleID,
                    focusedElementIdentity: signature.stableIdentity,
                    sourceRange: sourceRange,
                    boundaryUTF16Length: rendered.utf16.count,
                    caretAfterBoundary: start + needle.utf16.count,
                    expectedSource: source,
                    allowsKeyboardFallback: false
                )
            }
        }
        return nil
    }

    /// Whether keyboard focus is still on the anchored element with `range` selected.
    private static func selectionStillTargets(
        anchor: TextReplacementAnchor,
        element: AXUIElement,
        range: AXTextRange
    ) -> Bool {
        guard let current = focusedElementSignature(),
              current.pid == anchor.targetPID,
              current.stableIdentity == anchor.focusedElementIdentity
        else { return false }
        return selectedTextRange(for: element) == range
    }

    /// Whether a re-located field still sits in the window the chip was raised for.
    /// Web editors recreate their element proxies, so element identity cannot be
    /// required — but a same-app window switch must not redirect the fix.
    nonisolated static func isSameWindow(
        _ expected: FocusedElementSignature.StableIdentity,
        _ current: FocusedElementSignature.StableIdentity
    ) -> Bool {
        guard expected.pid == current.pid else { return false }
        if let lhs = expected.windowTitleHash, let rhs = current.windowTitleHash {
            return lhs == rhs
        }
        return true
    }

    /// `focusedElementSignature()` re-sampled as described on `focusSampleAttempts`.
    private static func resampledFocusedElementSignature() -> FocusedElementSignature? {
        for attempt in 0..<focusSampleAttempts {
            if attempt > 0 {
                Thread.sleep(forTimeInterval: focusSampleRetryDelay)
            }
            if let signature = focusedElementSignature() {
                return signature
            }
        }
        return nil
    }

    private static func isAttributeSettable(_ attribute: CFString, on element: AXUIElement) -> Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, attribute, &settable) == .success && settable.boolValue
    }

    private static func setSelectedTextRange(_ range: AXTextRange, on element: AXUIElement) -> Bool {
        var cfRange = range.cfRange
        guard let rangeValue = AXValueCreate(.cfRange, &cfRange) else { return false }
        return AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            rangeValue
        ) == .success
    }

    private static func stringAttribute(_ attribute: CFString, from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private static func windowTitleHash(for element: AXUIElement) -> Int? {
        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXWindowAttribute as CFString,
            &windowRef
        ) == .success,
              let windowRef,
              CFGetTypeID(windowRef) == AXUIElementGetTypeID()
        else {
            return stringAttribute(kAXTitleAttribute as CFString, from: element)?.stableHashValue
        }

        let window = unsafeBitCast(windowRef, to: AXUIElement.self)
        return stringAttribute(kAXTitleAttribute as CFString, from: window)?.stableHashValue
    }

    private static func frameHash(for element: AXUIElement) -> Int? {
        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let positionRef,
              let sizeRef,
              CFGetTypeID(positionRef) == AXValueGetTypeID(),
              CFGetTypeID(sizeRef) == AXValueGetTypeID()
        else {
            return nil
        }

        let positionValue = unsafeBitCast(positionRef, to: AXValue.self)
        let sizeValue = unsafeBitCast(sizeRef, to: AXValue.self)
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue, .cgPoint, &position),
              AXValueGetValue(sizeValue, .cgSize, &size)
        else {
            return nil
        }

        let rounded = [
            Int(position.x.rounded()),
            Int(position.y.rounded()),
            Int(size.width.rounded()),
            Int(size.height.rounded())
        ]
        return rounded.stableHashValue
    }

    private static func selectedRangeLocation(for element: AXUIElement) -> Int? {
        selectedTextRange(for: element)?.location
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }

    var stableHashValue: Int {
        unicodeScalars.reduce(5381) { hash, scalar in
            ((hash << 5) &+ hash) &+ Int(scalar.value)
        }
    }
}

private extension Array where Element == Int {
    var stableHashValue: Int {
        reduce(5381) { hash, value in
            ((hash << 5) &+ hash) &+ value
        }
    }
}
