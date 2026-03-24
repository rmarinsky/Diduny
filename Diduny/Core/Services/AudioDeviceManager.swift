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

    /// Resolve the device to use for recording.
    /// - `nil` preferredUID → System Default path (default → best → first), `didFallback = false`
    /// - non-nil preferredUID → look up in list; if missing, fallback chain with `didFallback = true`
    func resolveDevice(preferredUID: String?) -> (device: AudioDevice?, didFallback: Bool) {
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
        return (defaultDevice ?? bestDevice() ?? availableDevices.first, false)
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
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
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
}
