import CoreAudio
import Foundation

typealias AudioDeviceID = UInt32

/// Transport type of an audio device, used for auto-detection scoring.
enum AudioTransportType: String, Comparable {
    case usb
    case thunderbolt
    case firewire
    case builtIn
    case bluetooth
    case aggregate
    case virtual
    case unknown

    /// Lower score = higher priority for auto-detection.
    var priority: Int {
        switch self {
        case .usb: 1
        case .thunderbolt: 2
        case .firewire: 2
        case .builtIn: 3
        case .bluetooth: 4
        case .aggregate: 5
        case .virtual: 5
        case .unknown: 6
        }
    }

    static func < (lhs: AudioTransportType, rhs: AudioTransportType) -> Bool {
        lhs.priority < rhs.priority
    }

    var displayName: String {
        switch self {
        case .usb: "USB"
        case .thunderbolt: "Thunderbolt"
        case .firewire: "FireWire"
        case .builtIn: "Built-in"
        case .bluetooth: "Bluetooth"
        case .aggregate: "Aggregate"
        case .virtual: "Virtual"
        case .unknown: "Unknown"
        }
    }
}

struct AudioDevice: Identifiable, Equatable, Hashable {
    /// Stable UID string from the driver — persists across reboots.
    let uid: String
    /// Runtime device ID — NOT stable across reboots.
    let id: AudioDeviceID
    let name: String
    let inputChannels: Int
    let sampleRate: Double
    let transportType: AudioTransportType
    var isDefault: Bool

    static func == (lhs: AudioDevice, rhs: AudioDevice) -> Bool {
        lhs.uid == rhs.uid
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(uid)
    }
}
