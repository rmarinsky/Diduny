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

enum MicrophoneSelectionStrategy: String, CaseIterable, Identifiable {
    case manual
    case auto
    case preferNoiseReduction
    case preferFidelity

    var id: String {
        rawValue
    }

    var displayName: String {
        switch self {
        case .manual: "Manual"
        case .auto: "Auto"
        case .preferNoiseReduction: "Noise"
        case .preferFidelity: "Fidelity"
        }
    }

    var helpText: String {
        switch self {
        case .manual:
            "Use the exact microphone you selected below."
        case .auto:
            "Balance proximity, noise handling, and fidelity."
        case .preferNoiseReduction:
            "Prefer headset-style microphones like AirPods in noisy places."
        case .preferFidelity:
            "Prefer built-in or wired microphones with wider bandwidth."
        }
    }
}

struct AudioDeviceScore {
    let total: Int
    let summary: String
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

    private var normalizedName: String {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
    }

    var isBluetooth: Bool {
        transportType == .bluetooth
    }

    var isBuiltInMic: Bool {
        transportType == .builtIn || normalizedName.contains("macbook") || normalizedName.contains("built-in")
    }

    var isAirPodsLike: Bool {
        normalizedName.contains("airpods") || normalizedName.contains("beats fit pro")
    }

    var isHeadsetLike: Bool {
        isAirPodsLike ||
            normalizedName.contains("headset") ||
            normalizedName.contains("headphones") ||
            normalizedName.contains("earpods") ||
            normalizedName.contains("buds") ||
            normalizedName.contains("jabra") ||
            normalizedName.contains("plantronics")
    }

    var qualityHint: String {
        if isAirPodsLike {
            return "Close mic, better in noise, lower bandwidth"
        }
        if isHeadsetLike {
            return "Headset mic, usually better in noise"
        }
        if isBuiltInMic {
            return "Wider capture, may pick up more room noise"
        }
        if transportType == .usb || transportType == .thunderbolt || transportType == .firewire {
            return "External mic, usually best fidelity"
        }
        if transportType == .bluetooth {
            return "Bluetooth mic, voice-optimized but bandwidth-limited"
        }
        return "General-purpose input device"
    }
}
