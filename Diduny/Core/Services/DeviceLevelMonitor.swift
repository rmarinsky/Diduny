import AVFoundation
import CoreAudio
import os

@MainActor
@Observable
final class DeviceLevelMonitor {
    var audioLevel: Float = 0

    private var engine: AVAudioEngine?
    private nonisolated let _audioLevelBox = OSAllocatedUnfairLock<Float>(initialState: 0)
    private var pollingTimer: DispatchSourceTimer?

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

            self?._audioLevelBox.withLock { $0 = level }
        }

        do {
            try engine.start()
        } catch {
            self.engine = nil
            return
        }

        startPollingTimer()
    }

    func stopMonitoring() {
        pollingTimer?.cancel()
        pollingTimer = nil
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
        audioLevel = 0
    }

    private func startPollingTimer() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: 1.0 / 25.0)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let latest = self._audioLevelBox.withLock { $0 }
            if abs(latest - self.audioLevel) > 0.01 {
                self.audioLevel = latest
            }
        }
        timer.resume()
        pollingTimer = timer
    }
}
