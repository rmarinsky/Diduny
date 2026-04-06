import AVFoundation
import CoreAudio
import Foundation
import Observation

@Observable
final class AudioDeviceManager: AudioDeviceManagerProtocol {
    private(set) var availableDevices: [AudioDevice] = [] {
        didSet {
            onDevicesChanged?(availableDevices)
        }
    }

    private(set) var defaultDevice: AudioDevice?

    @ObservationIgnored
    var onDevicesChanged: (([AudioDevice]) -> Void)?

    @ObservationIgnored
    private var debounceWorkItem: DispatchWorkItem?

    /// Debounce interval for device change notifications (CoreAudio can fire multiple rapid events).
    private let debounceInterval: TimeInterval = 0.3

    init() {
        refreshDevices()
        setupDeviceChangeListener()
    }

    // MARK: - Public Methods

    func refreshDevices() {
        availableDevices = getInputDevices()
        defaultDevice = availableDevices.first { $0.isDefault }
    }

    /// Check if a device with the given UID is currently available
    func isDeviceAvailable(uid: String) -> Bool {
        availableDevices.contains { $0.uid == uid }
    }

    /// Returns the preferred UID if that device is still available, otherwise `nil` (System Default).
    func effectiveDeviceUID(preferred: String?) -> String? {
        guard let uid = preferred else { return nil }
        return isDeviceAvailable(uid: uid) ? uid : nil
    }

    /// Get device by UID, returns nil if not available
    func device(forUID uid: String) -> AudioDevice? {
        availableDevices.first { $0.uid == uid }
    }

    func score(for device: AudioDevice, strategy: MicrophoneSelectionStrategy) -> AudioDeviceScore {
        let score: Int
        let summary: String

        switch strategy {
        case .manual:
            score = 0
            summary = "Manual selection"
        case .auto:
            score = autoScore(for: device)
            summary = autoSummary(for: device)
        case .preferNoiseReduction:
            score = noiseReductionScore(for: device)
            summary = noiseReductionSummary(for: device)
        case .preferFidelity:
            score = fidelityScore(for: device)
            summary = fidelitySummary(for: device)
        }

        return AudioDeviceScore(total: score, summary: summary)
    }

    func recommendedDevice(strategy: MicrophoneSelectionStrategy) -> AudioDevice? {
        guard !availableDevices.isEmpty else { return nil }
        guard strategy != .manual else { return defaultDevice ?? bestDevice() ?? availableDevices.first }

        return availableDevices.max { lhs, rhs in
            let leftScore = score(for: lhs, strategy: strategy).total
            let rightScore = score(for: rhs, strategy: strategy).total
            if leftScore != rightScore {
                return leftScore < rightScore
            }
            if lhs.transportType != rhs.transportType {
                return lhs.transportType.priority > rhs.transportType.priority
            }
            if lhs.sampleRate != rhs.sampleRate {
                return lhs.sampleRate < rhs.sampleRate
            }
            return lhs.inputChannels < rhs.inputChannels
        }
    }

    /// Resolve the device to use for recording.
    /// - `nil` preferredUID → System Default path (default → best → first), `didFallback = false`
    /// - non-nil preferredUID → look up in list; if missing, fallback chain with `didFallback = true`
    func resolveDevice(preferredUID: String?) -> (device: AudioDevice?, didFallback: Bool) {
        resolveDevice(preferredUID: preferredUID, strategy: .manual)
    }

    /// Resolve the device to use for recording with strategy support.
    /// Explicit device selection always wins; strategy is used only for System Default mode.
    func resolveDevice(preferredUID: String?,
                       strategy: MicrophoneSelectionStrategy) -> (device: AudioDevice?, didFallback: Bool)
    {
        if let uid = preferredUID {
            // Preferred device set — try to find it
            if let device = device(forUID: uid) {
                return (device, false)
            }
            // Stale list? Refresh and retry
            refreshDevices()
            if let device = device(forUID: uid) {
                return (device, false)
            }
            // Preferred device unavailable — fallback
            return (defaultDevice ?? bestDevice() ?? availableDevices.first, true)
        }

        // nil = System Default
        switch strategy {
        case .manual:
            return (defaultDevice ?? bestDevice() ?? availableDevices.first, false)
        case .auto, .preferNoiseReduction, .preferFidelity:
            return (
                recommendedDevice(strategy: strategy) ?? defaultDevice ?? bestDevice() ?? availableDevices.first,
                false
            )
        }
    }

    /// Score-based auto-detection: picks the best microphone based on transport type and capabilities.
    /// Priority: USB > Thunderbolt/FireWire > Built-in > Bluetooth > Aggregate/Virtual
    /// Tie-breaking: higher sample rate wins, then more input channels.
    func bestDevice() -> AudioDevice? {
        availableDevices
            .filter { $0.transportType != .aggregate && $0.transportType != .virtual }
            .min { lhs, rhs in
                if lhs.transportType != rhs.transportType {
                    return lhs.transportType < rhs.transportType
                }
                if lhs.sampleRate != rhs.sampleRate {
                    return lhs.sampleRate > rhs.sampleRate
                }
                return lhs.inputChannels > rhs.inputChannels
            }
    }

    // MARK: - Private Methods

    private func getInputDevices() -> [AudioDevice] {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize
        )

        guard status == noErr else { return [] }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)

        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize,
            &deviceIDs
        )

        guard status == noErr else { return [] }

        let defaultInputID = getDefaultInputDeviceID()

        return deviceIDs.compactMap { deviceID -> AudioDevice? in
            guard let name = getDeviceName(deviceID),
                  let uid = getDeviceUID(deviceID),
                  let inputChannels = getInputChannelCount(deviceID),
                  inputChannels > 0
            else {
                return nil
            }

            let sampleRate = getDeviceSampleRate(deviceID) ?? 44100
            let transportType = getTransportType(deviceID)

            // Hide virtual and aggregate devices — they are internal plumbing
            // (e.g. Teams Audio, ScreenCaptureKit aggregates) not useful for dictation.
            if transportType == .virtual || transportType == .aggregate {
                return nil
            }

            return AudioDevice(
                uid: uid,
                id: deviceID,
                name: name,
                inputChannels: inputChannels,
                sampleRate: sampleRate,
                transportType: transportType,
                isDefault: deviceID == defaultInputID
            )
        }
    }

    private func getDefaultInputDeviceID() -> AudioDeviceID? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var deviceID: AudioDeviceID = 0
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize,
            &deviceID
        )

        return status == noErr ? deviceID : nil
    }

    private func getDeviceName(_ deviceID: AudioDeviceID) -> String? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var name: Unmanaged<CFString>?
        var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)

        let status = withUnsafeMutablePointer(to: &name) { namePtr in
            AudioObjectGetPropertyData(
                deviceID,
                &propertyAddress,
                0,
                nil,
                &dataSize,
                namePtr
            )
        }

        guard status == noErr, let unmanagedName = name else { return nil }
        return unmanagedName.takeRetainedValue() as String
    }

    private func getDeviceUID(_ deviceID: AudioDeviceID) -> String? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var uid: Unmanaged<CFString>?
        var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)

        let status = withUnsafeMutablePointer(to: &uid) { uidPtr in
            AudioObjectGetPropertyData(
                deviceID,
                &propertyAddress,
                0,
                nil,
                &dataSize,
                uidPtr
            )
        }

        guard status == noErr, let unmanagedUID = uid else { return nil }
        return unmanagedUID.takeRetainedValue() as String
    }

    private func getTransportType(_ deviceID: AudioDeviceID) -> AudioTransportType {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var transportType: UInt32 = 0
        var dataSize = UInt32(MemoryLayout<UInt32>.size)

        let status = AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nil, &dataSize, &transportType)
        guard status == noErr else { return .unknown }

        switch transportType {
        case kAudioDeviceTransportTypeUSB:
            return .usb
        case kAudioDeviceTransportTypeThunderbolt:
            return .thunderbolt
        case kAudioDeviceTransportTypeFireWire:
            return .firewire
        case kAudioDeviceTransportTypeBuiltIn:
            return .builtIn
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            return .bluetooth
        case kAudioDeviceTransportTypeAggregate:
            return .aggregate
        case kAudioDeviceTransportTypeVirtual:
            return .virtual
        default:
            return .unknown
        }
    }

    private func getInputChannelCount(_ deviceID: AudioDeviceID) -> Int? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(deviceID, &propertyAddress, 0, nil, &dataSize)
        guard status == noErr, dataSize > 0 else { return nil }

        let bufferListPointer = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: Int(dataSize))
        defer { bufferListPointer.deallocate() }

        status = AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nil, &dataSize, bufferListPointer)
        guard status == noErr else { return nil }

        let bufferList = bufferListPointer.pointee
        var channelCount = 0

        for i in 0 ..< Int(bufferList.mNumberBuffers) {
            let buffer = withUnsafePointer(to: &bufferListPointer.pointee.mBuffers) {
                $0.advanced(by: i).pointee
            }
            channelCount += Int(buffer.mNumberChannels)
        }

        return channelCount
    }

    private func getDeviceSampleRate(_ deviceID: AudioDeviceID) -> Double? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var sampleRate: Float64 = 0
        var dataSize = UInt32(MemoryLayout<Float64>.size)

        let status = AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nil, &dataSize, &sampleRate)
        return status == noErr ? sampleRate : nil
    }

    private func setupDeviceChangeListener() {
        // Listen for device list changes (connect/disconnect)
        var devicesAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &devicesAddress,
            DispatchQueue.main
        ) { [weak self] _, _ in
            self?.debouncedRefresh()
        }

        // Listen for default input device changes (user switches in System Settings)
        var defaultInputAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultInputAddress,
            DispatchQueue.main
        ) { [weak self] _, _ in
            self?.debouncedRefresh()
        }
    }

    private func debouncedRefresh() {
        debounceWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.refreshDevices()
        }
        debounceWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + debounceInterval, execute: workItem)
    }

    private func autoScore(for device: AudioDevice) -> Int {
        var score = baseHardwareScore(for: device)

        if device.isAirPodsLike {
            score += 24
        } else if device.isHeadsetLike {
            score += 18
        }

        if device.isBuiltInMic {
            score += 12
        }

        if device.isBluetooth, !device.isHeadsetLike {
            score -= 8
        }

        return score
    }

    private func noiseReductionScore(for device: AudioDevice) -> Int {
        var score = baseHardwareScore(for: device)

        if device.isAirPodsLike {
            score += 32
        } else if device.isHeadsetLike {
            score += 24
        }

        if device.isBuiltInMic {
            score -= 6
        }

        return score
    }

    private func fidelityScore(for device: AudioDevice) -> Int {
        var score = baseHardwareScore(for: device)
        score += Int(device.sampleRate / 2000)

        switch device.transportType {
        case .usb:
            score += 28
        case .thunderbolt, .firewire:
            score += 24
        case .builtIn:
            score += 18
        case .bluetooth:
            score -= 20
        case .aggregate, .virtual, .unknown:
            break
        }

        if device.isAirPodsLike {
            score -= 8
        }

        return score
    }

    private func baseHardwareScore(for device: AudioDevice) -> Int {
        var score = 0
        score += min(device.inputChannels, 2) * 4
        score += Int(min(device.sampleRate, 48000) / 4000)
        if device.isDefault {
            score += 2
        }
        return score
    }

    private func autoSummary(for device: AudioDevice) -> String {
        if device.isAirPodsLike {
            return "Good balance for speech in noise"
        }
        if device.isHeadsetLike {
            return "Headset mic with strong voice focus"
        }
        if device.isBuiltInMic {
            return "Balanced fallback with wider capture"
        }
        if device.transportType == .usb || device.transportType == .thunderbolt || device.transportType == .firewire {
            return "External mic with strong overall quality"
        }
        return device.qualityHint
    }

    private func noiseReductionSummary(for device: AudioDevice) -> String {
        if device.isAirPodsLike {
            return "Best for noisy places and close speech pickup"
        }
        if device.isHeadsetLike {
            return "Headset-style mic preferred in noise"
        }
        if device.isBuiltInMic {
            return "Usable, but may capture more room noise"
        }
        return device.qualityHint
    }

    private func fidelitySummary(for device: AudioDevice) -> String {
        if device.transportType == .usb || device.transportType == .thunderbolt || device.transportType == .firewire {
            return "Preferred for cleaner, fuller-band capture"
        }
        if device.isBuiltInMic {
            return "Good bandwidth, but more room pickup"
        }
        if device.isBluetooth {
            return "Voice-optimized, but bandwidth-limited"
        }
        return device.qualityHint
    }
}
