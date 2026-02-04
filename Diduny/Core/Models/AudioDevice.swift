import CoreAudio
import Foundation

typealias AudioDeviceID = UInt32

struct AudioDevice: Identifiable, Equatable, Hashable {
    let id: AudioDeviceID
    let name: String
    let inputChannels: Int
    let sampleRate: Double
    var isDefault: Bool

    static func == (lhs: AudioDevice, rhs: AudioDevice) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
