import AVFoundation
import CoreAudio

@MainActor
@Observable
final class DeviceLevelMonitor {
    var audioLevel: Float = 0

    private var engine: AVAudioEngine?

    func startMonitoring(deviceID: AudioDeviceID) {
        stopMonitoring()

        let engine = AVAudioEngine()
        self.engine = engine

        let node = engine.inputNode
        guard let audioUnit = node.audioUnit else { return }

        var mutableDeviceID = deviceID
        AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &mutableDeviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )

        // Prepare preallocates resources and forces the audio unit to fully
        // configure with the new device — without this, outputFormat can
        // return an empty format on the first engine created in the process.
        engine.prepare()

        let format = node.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { return }

        node.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            guard let channelData = buffer.floatChannelData?[0] else { return }
            let frameLength = Int(buffer.frameLength)
            guard frameLength > 0 else { return }

            var sum: Float = 0
            for i in 0..<frameLength {
                let sample = channelData[i]
                sum += sample * sample
            }
            let rms = sqrt(sum / Float(frameLength))
            let db = 20 * log10(max(rms, 0.0001))
            let minDb: Float = -60
            let level = max(0, min(1, (db - minDb) / -minDb))

            Task { @MainActor in
                self?.audioLevel = level
            }
        }

        do {
            try engine.start()
        } catch {
            self.engine = nil
        }
    }

    func stopMonitoring() {
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
        audioLevel = 0
    }
}
