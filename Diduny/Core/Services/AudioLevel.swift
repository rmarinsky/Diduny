import Accelerate
import Foundation

/// The 0...1 meter level of a buffer: RMS in dB over a 60 dB range, the same mapping the microphone test uses.
enum AudioLevel {
    static func normalized(rms: Float) -> Float {
        let db = 20 * log10(max(rms, 0.0001))
        let minDb: Float = -60
        return max(0, min(1, (db - minDb) / -minDb))
    }

    static func of(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var rms: Float = 0
        vDSP_rmsqv(samples, 1, &rms, vDSP_Length(samples.count))
        return normalized(rms: rms)
    }
}
