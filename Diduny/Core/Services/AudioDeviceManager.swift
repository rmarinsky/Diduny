import AVFoundation
import Combine
import CoreAudio
import Foundation

final class AudioDeviceManager: ObservableObject, AudioDeviceManagerProtocol {
    @Published private(set) var availableDevices: [AudioDevice] = []
    @Published private(set) var defaultDevice: AudioDevice?

    private var deviceChangeObserver: Any?

    init() {
        refreshDevices()
        setupDeviceChangeListener()
    }

    deinit {
        if let observer = deviceChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Public Methods

    func refreshDevices() {
        availableDevices = getInputDevices()
        defaultDevice = availableDevices.first { $0.isDefault }
    }

    /// Check if a device with the given ID is currently available
    func isDeviceAvailable(_ deviceID: AudioDeviceID) -> Bool {
        availableDevices.contains { $0.id == deviceID }
    }

    /// Get device by ID, returns nil if not available
    func device(for deviceID: AudioDeviceID) -> AudioDevice? {
        availableDevices.first { $0.id == deviceID }
    }

    /// Get the current system default input device (refreshes first to ensure accuracy)
    func getCurrentDefaultDevice() -> AudioDevice? {
        refreshDevices()
        return defaultDevice
    }

    /// Check if device is alive using CoreAudio property
    /// This is more reliable than checking the cached device list
    func isDeviceAlive(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var isAlive: UInt32 = 0
        var propertySize = UInt32(MemoryLayout<UInt32>.size)

        let status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &propertySize,
            &isAlive
        )

        return status == noErr && isAlive == 1
    }

    /// Get a valid device, falling back to default if selected is unavailable
    /// Returns tuple with device and whether fallback was used
    func getValidDevice(selectedID: AudioDeviceID?) -> (device: AudioDevice?, didFallback: Bool) {
        // First try the selected device
        if let selectedID = selectedID,
           isDeviceAlive(selectedID),
           let device = device(for: selectedID) {
            return (device, false)
        }

        // Fallback to default device
        refreshDevices()
        return (defaultDevice, selectedID != nil)
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
                  let inputChannels = getInputChannelCount(deviceID),
                  inputChannels > 0
            else {
                return nil
            }

            let sampleRate = getDeviceSampleRate(deviceID) ?? 44100

            return AudioDevice(
                id: deviceID,
                name: name,
                inputChannels: inputChannels,
                sampleRate: sampleRate,
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
            self?.refreshDevices()
        }
    }
}
