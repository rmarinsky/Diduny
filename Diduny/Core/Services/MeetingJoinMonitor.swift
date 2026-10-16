import AppKit
import CoreAudio
import CoreGraphics
import Foundation
import OSLog
import ScreenCaptureKit

enum MeetingClient: String, CaseIterable, Equatable {
    case zoom
    case teams
    case googleMeet
    case webex
    case slackHuddle
    case faceTime

    var displayName: String {
        switch self {
        case .zoom: String(localized: "Zoom")
        case .teams: String(localized: "Microsoft Teams")
        case .googleMeet: String(localized: "Google Meet")
        case .webex: String(localized: "Webex")
        case .slackHuddle: String(localized: "Slack Huddle")
        case .faceTime: String(localized: "FaceTime")
        }
    }
}

struct DetectedMeeting: Equatable {
    let id: UUID
    let client: MeetingClient
}

enum MeetingPresenceEvent: Equatable {
    case joined(DetectedMeeting)
    case ended(DetectedMeeting)
}

struct MeetingSignal: Equatable {
    enum Source: Equatable {
        case native
        case browser
    }

    let client: MeetingClient
    let source: Source
    let isInputActive: Bool
    let isOutputActive: Bool
    let hasCallWindow: Bool
    let isFrontmostCallWindow: Bool

    var isValid: Bool {
        switch source {
        case .native:
            (isInputActive && isOutputActive)
                || (hasCallWindow && (isInputActive || isOutputActive))
        case .browser:
            hasCallWindow && (isInputActive || isOutputActive)
        }
    }
}

struct MeetingAudioProcessSnapshot: Equatable {
    let bundleIdentifier: String
    let isInputActive: Bool
    let isOutputActive: Bool
}

struct MeetingWindowSnapshot: Equatable {
    let bundleIdentifier: String
    let title: String
    let isFrontmost: Bool
}

private struct MeetingWindowCandidate {
    let id: CGWindowID
    let bundleIdentifier: String
    let title: String
}

@MainActor
final class MeetingJoinMonitor {
    typealias SnapshotProvider = () async -> [MeetingSignal]
    typealias Clock = () -> Date
    typealias Sleeper = (TimeInterval) async throws -> Void

    private enum State {
        case idle
        case candidate(client: MeetingClient, firstSeenAt: Date)
        case prompted(meeting: DetectedMeeting, lastSeenAt: Date)
        case ended
    }

    private let snapshot: SnapshotProvider
    private let now: Clock
    private let sleep: Sleeper
    private var state: State = .idle
    private var pollingTask: Task<Void, Never>?
    private var onEvent: ((MeetingPresenceEvent) -> Void)?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var scanInFlight = false
    private var scanGeneration: UInt = 0

    init(
        snapshot: @escaping SnapshotProvider = { await MeetingJoinMonitor.captureSignals() },
        now: @escaping Clock = Date.init,
        sleep: @escaping Sleeper = { seconds in
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
    ) {
        self.snapshot = snapshot
        self.now = now
        self.sleep = sleep
    }

    func start(onEvent: @escaping (MeetingPresenceEvent) -> Void) {
        guard SettingsStorage.shared.meetingSuggestionsEnabled, pollingTask == nil else { return }
        self.onEvent = onEvent
        installWorkspaceObservers()
        pollingTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await pollOnce()
                do {
                    try await sleep(1)
                } catch {
                    return
                }
            }
        }
    }

    func stop() {
        scanGeneration &+= 1
        pollingTask?.cancel()
        pollingTask = nil
        let notificationCenter = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach { notificationCenter.removeObserver($0) }
        workspaceObservers.removeAll()
        onEvent = nil
        scanInFlight = false
        state = .idle
    }

    private func pollOnce() async {
        let generation = scanGeneration
        guard pollingTask != nil, !scanInFlight else { return }
        scanInFlight = true
        let signals = await snapshot()
        guard generation == scanGeneration else { return }
        scanInFlight = false
        guard pollingTask != nil, let event = ingest(signals, at: now()) else { return }
        onEvent?(event)
    }

    private func installWorkspaceObservers() {
        let notificationCenter = NSWorkspace.shared.notificationCenter
        for name in [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification
        ] {
            workspaceObservers.append(
                notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                    guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                        as? NSRunningApplication,
                        let bundleIdentifier = application.bundleIdentifier
                    else { return }
                    Task { @MainActor [weak self] in
                        guard Self.isSupportedApplicationBundle(bundleIdentifier) else { return }
                        await self?.pollOnce()
                    }
                }
            )
        }
    }
}

extension MeetingJoinMonitor {
    private struct CoreAudioScan {
        let processes: [MeetingAudioProcessSnapshot]
        let supportsProcessActivity: Bool
        let systemInputActive: Bool
    }

    private nonisolated static func captureSignals() async -> [MeetingSignal] {
        let audio = readCoreAudioActivity()
        let hasAudioCandidate = audio.supportsProcessActivity
            ? audio.processes.contains {
                ($0.isInputActive || $0.isOutputActive)
                    && isSupportedApplicationBundle($0.bundleIdentifier)
            }
            : audio.systemInputActive
        guard hasAudioCandidate else { return [] }

        return await signals(
            audio: audio.processes,
            windows: readMeetingWindows(),
            supportsProcessActivity: audio.supportsProcessActivity,
            systemInputActive: audio.systemInputActive
        )
    }

    private nonisolated static func readCoreAudioActivity() -> CoreAudioScan {
        let systemObjectID = AudioObjectID(kAudioObjectSystemObject)
        var processListAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(systemObjectID, &processListAddress),
              let processObjectIDs = readObjectIDs(
                  from: systemObjectID,
                  address: &processListAddress
              )
        else {
            return CoreAudioScan(
                processes: [],
                supportsProcessActivity: false,
                systemInputActive: isSystemInputActive()
            )
        }

        let processes = processObjectIDs.compactMap { objectID -> MeetingAudioProcessSnapshot? in
            guard let bundleIdentifier = readBundleIdentifier(from: objectID) else { return nil }
            return MeetingAudioProcessSnapshot(
                bundleIdentifier: bundleIdentifier,
                isInputActive: readBooleanProperty(
                    kAudioProcessPropertyIsRunningInput,
                    from: objectID
                ),
                isOutputActive: readBooleanProperty(
                    kAudioProcessPropertyIsRunningOutput,
                    from: objectID
                )
            )
        }
        return CoreAudioScan(
            processes: processes,
            supportsProcessActivity: true,
            systemInputActive: false
        )
    }

    private nonisolated static func readObjectIDs(
        from objectID: AudioObjectID,
        address: inout AudioObjectPropertyAddress
    ) -> [AudioObjectID]? {
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &dataSize) == noErr,
              dataSize >= MemoryLayout<AudioObjectID>.size
        else { return nil }

        var values = [AudioObjectID](
            repeating: kAudioObjectUnknown,
            count: Int(dataSize) / MemoryLayout<AudioObjectID>.size
        )
        let status = values.withUnsafeMutableBytes { buffer in
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &dataSize, buffer.baseAddress!)
        }
        return status == noErr ? values : nil
    }

    private nonisolated static func readBundleIdentifier(from objectID: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(objectID, &address) else { return nil }
        var value: Unmanaged<CFString>?
        var dataSize = UInt32(MemoryLayout.size(ofValue: value))
        guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &dataSize, &value) == noErr,
              let value
        else { return nil }
        return value.takeRetainedValue() as String
    }

    private nonisolated static func readBooleanProperty(
        _ selector: AudioObjectPropertySelector,
        from objectID: AudioObjectID,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(objectID, &address) else { return false }
        var value: UInt32 = 0
        var dataSize = UInt32(MemoryLayout.size(ofValue: value))
        return AudioObjectGetPropertyData(objectID, &address, 0, nil, &dataSize, &value) == noErr
            && value != 0
    }

    private nonisolated static func isSystemInputActive() -> Bool {
        let systemObjectID = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var dataSize = UInt32(MemoryLayout.size(ofValue: deviceID))
        guard AudioObjectGetPropertyData(
            systemObjectID,
            &address,
            0,
            nil,
            &dataSize,
            &deviceID
        ) == noErr, deviceID != AudioObjectID(kAudioObjectUnknown) else { return false }
        return readBooleanProperty(
            kAudioDevicePropertyDeviceIsRunningSomewhere,
            from: deviceID,
            scope: kAudioObjectPropertyScopeInput
        )
    }

    private nonisolated static func readMeetingWindows() async -> [MeetingWindowSnapshot] {
        guard CGPreflightScreenCaptureAccess() else { return [] }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
            let candidates = content.windows.compactMap { window -> MeetingWindowCandidate? in
                guard let bundleIdentifier = window.owningApplication?.bundleIdentifier,
                      isSupportedApplicationBundle(bundleIdentifier),
                      let title = window.title,
                      !title.isEmpty
                else { return nil }
                return MeetingWindowCandidate(
                    id: window.windowID,
                    bundleIdentifier: bundleIdentifier,
                    title: title
                )
            }
            let callWindowIDs = candidates.compactMap { candidate in
                isCallWindow(
                    bundleIdentifier: candidate.bundleIdentifier,
                    title: candidate.title
                ) ? candidate.id : nil
            }
            let frontmostID = frontmostCallWindowID(
                callWindowIDs: callWindowIDs,
                orderedWindowIDs: orderedOnScreenWindowIDs()
            )
            return candidates.map { candidate in
                MeetingWindowSnapshot(
                    bundleIdentifier: candidate.bundleIdentifier,
                    title: candidate.title,
                    isFrontmost: candidate.id == frontmostID
                )
            }
        } catch {
            return []
        }
    }

    nonisolated static func frontmostCallWindowID(
        callWindowIDs: [CGWindowID],
        orderedWindowIDs: [CGWindowID]
    ) -> CGWindowID? {
        let callWindowIDs = Set(callWindowIDs)
        return orderedWindowIDs.first(where: callWindowIDs.contains)
    }

    private nonisolated static func orderedOnScreenWindowIDs() -> [CGWindowID] {
        guard let windowInfo = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return [] }
        return windowInfo.compactMap { entry in
            (entry[kCGWindowNumber as String] as? NSNumber)?.uint32Value
        }
    }

    private nonisolated static func isCallWindow(bundleIdentifier: String, title: String) -> Bool {
        if let client = nativeMeetingClient(for: bundleIdentifier) {
            return isNativeCallWindow(title: title, client: client)
        }
        return BrowserKind.allCases.contains {
            belongsToBundleFamily(bundleIdentifier, root: $0.bundleIdentifier)
        } && browserMeetingClient(for: title) != nil
    }

    nonisolated static func signals(
        audio: [MeetingAudioProcessSnapshot],
        windows: [MeetingWindowSnapshot],
        supportsProcessActivity: Bool = true,
        systemInputActive: Bool = false
    ) -> [MeetingSignal] {
        var result: [MeetingSignal] = []

        for client in MeetingClient.allCases {
            let nativeAudio = audio.filter { nativeMeetingClient(for: $0.bundleIdentifier) == client }
            let nativeWindows = windows.filter {
                nativeMeetingClient(for: $0.bundleIdentifier) == client
                    && isNativeCallWindow(title: $0.title, client: client)
            }
            let nativeSignal = MeetingSignal(
                client: client,
                source: .native,
                isInputActive: supportsProcessActivity
                    ? nativeAudio.contains(where: \.isInputActive)
                    : systemInputActive,
                isOutputActive: supportsProcessActivity
                    ? nativeAudio.contains(where: \.isOutputActive)
                    : false,
                hasCallWindow: !nativeWindows.isEmpty,
                isFrontmostCallWindow: nativeWindows.contains(where: \.isFrontmost)
            )
            if nativeSignal.isValid {
                result.append(nativeSignal)
            }

            let matchingWindows = windows.compactMap { window -> (MeetingWindowSnapshot, BrowserKind)? in
                guard let browser = BrowserKind.allCases.first(where: {
                    belongsToBundleFamily(window.bundleIdentifier, root: $0.bundleIdentifier)
                }), browserMeetingClient(for: window.title) == client else { return nil }
                return (window, browser)
            }
            .sorted { $0.0.isFrontmost && !$1.0.isFrontmost }

            for (window, browser) in matchingWindows {
                let browserAudio = audio.filter {
                    browserOwnsAudioBundle($0.bundleIdentifier, browser: browser)
                }
                let isInputActive = supportsProcessActivity
                    ? browserAudio.contains(where: \.isInputActive)
                    : systemInputActive
                let isOutputActive = supportsProcessActivity
                    ? browserAudio.contains(where: \.isOutputActive)
                    : false
                let signal = MeetingSignal(
                    client: client,
                    source: .browser,
                    isInputActive: isInputActive,
                    isOutputActive: isOutputActive,
                    hasCallWindow: true,
                    isFrontmostCallWindow: window.isFrontmost
                )
                if signal.isValid {
                    result.append(signal)
                    break
                }
            }
        }

        return result
    }
}

extension MeetingJoinMonitor {
    func ingest(_ signals: [MeetingSignal], at now: Date) -> MeetingPresenceEvent? {
        if case let .prompted(meeting, lastSeenAt) = state {
            if signals.contains(where: { $0.isValid && $0.client == meeting.client }) {
                state = .prompted(meeting: meeting, lastSeenAt: now)
                return nil
            }
            guard now.timeIntervalSince(lastSeenAt) >= 30 else { return nil }
            state = .ended
            Log.app.info("Meeting \(meeting.client.rawValue, privacy: .public): prompted -> ended")
            return .ended(meeting)
        }

        guard let signal = preferredSignal(in: signals) else {
            switch state {
            case .candidate:
                state = .idle
            default:
                break
            }
            return nil
        }

        switch state {
        case .idle, .ended:
            state = .candidate(client: signal.client, firstSeenAt: now)
            Log.app.debug("Meeting \(signal.client.rawValue, privacy: .public): idle -> candidate")
            return nil
        case let .candidate(client, firstSeenAt):
            guard client == signal.client else {
                state = .candidate(client: signal.client, firstSeenAt: now)
                Log.app.debug("Meeting \(signal.client.rawValue, privacy: .public): candidate -> candidate")
                return nil
            }
            guard now.timeIntervalSince(firstSeenAt) >= 1 else { return nil }
            let meeting = DetectedMeeting(id: UUID(), client: client)
            state = .prompted(meeting: meeting, lastSeenAt: now)
            Log.app.info("Meeting \(client.rawValue, privacy: .public): candidate -> prompted")
            return .joined(meeting)
        case .prompted:
            return nil
        }
    }

    private func preferredSignal(in signals: [MeetingSignal]) -> MeetingSignal? {
        signals.filter(\.isValid).min { left, right in
            if left.isFrontmostCallWindow != right.isFrontmostCallWindow {
                return left.isFrontmostCallWindow
            }
            let leftIsDuplex = left.isInputActive && left.isOutputActive
            let rightIsDuplex = right.isInputActive && right.isOutputActive
            if leftIsDuplex != rightIsDuplex {
                return leftIsDuplex
            }
            let leftIndex = MeetingClient.allCases.firstIndex(of: left.client) ?? .max
            let rightIndex = MeetingClient.allCases.firstIndex(of: right.client) ?? .max
            return leftIndex < rightIndex
        }
    }

    private nonisolated static func belongsToBundleFamily(_ bundleIdentifier: String, root: String) -> Bool {
        bundleIdentifier == root || bundleIdentifier.hasPrefix(root + ".")
    }

    private nonisolated static func isSupportedApplicationBundle(_ bundleIdentifier: String) -> Bool {
        nativeMeetingClient(for: bundleIdentifier) != nil
            || BrowserKind.allCases.contains { browser in
                belongsToBundleFamily(bundleIdentifier, root: browser.bundleIdentifier)
                    || browserOwnsAudioBundle(bundleIdentifier, browser: browser)
            }
    }

    private nonisolated static func browserOwnsAudioBundle(
        _ bundleIdentifier: String,
        browser: BrowserKind
    ) -> Bool {
        belongsToBundleFamily(bundleIdentifier, root: browser.bundleIdentifier)
            || (browser == .safari && bundleIdentifier.hasPrefix("com.apple.WebKit."))
    }

    private nonisolated static func browserMeetingClient(for title: String) -> MeetingClient? {
        let title = title.lowercased()
        if title.contains("google meet")
            || title.range(of: #"\bmeet\b.*\b[a-z]{3}-[a-z]{4}-[a-z]{3}\b"#, options: .regularExpression) != nil
        {
            return .googleMeet
        }
        if title.contains("zoom"), title.contains("meeting") || title.contains("webinar") {
            return .zoom
        }
        if title.contains("microsoft teams"), title.contains("meeting") || title.contains("call") {
            return .teams
        }
        if title.contains("webex"), title.contains("meeting") || title.contains("personal room") {
            return .webex
        }
        return nil
    }

    private nonisolated static func nativeMeetingClient(for bundleIdentifier: String) -> MeetingClient? {
        if bundleIdentifier.hasPrefix("us.zoom.") {
            return .zoom
        }
        if bundleIdentifier == "com.microsoft.teams"
            || bundleIdentifier.hasPrefix("com.microsoft.teams.")
            || bundleIdentifier.hasPrefix("com.microsoft.teams2")
        {
            return .teams
        }
        if bundleIdentifier.hasPrefix("Cisco-Systems.Spark")
            || bundleIdentifier.hasPrefix("com.cisco.webexmeetingsapp")
        {
            return .webex
        }
        if bundleIdentifier.hasPrefix("com.tinyspeck.slackmacgap") {
            return .slackHuddle
        }
        if bundleIdentifier == "com.apple.FaceTime" {
            return .faceTime
        }
        return nil
    }

    private nonisolated static func isNativeCallWindow(title: String, client: MeetingClient) -> Bool {
        let title = title.lowercased()
        switch client {
        case .zoom:
            return ["meeting", "webinar", "waiting room", "joining"].contains(where: title.contains)
        case .teams:
            return ["meeting", "call", "lobby"].contains(where: title.contains)
        case .webex:
            return ["meeting", "webinar", "personal room"].contains(where: title.contains)
        case .slackHuddle:
            return title.contains("huddle")
        case .faceTime:
            return title.contains("facetime") || title.contains("call")
        case .googleMeet:
            return false
        }
    }
}
