import Foundation
import IOKit.ps
import Observation

/// What powers the Mac right now.
enum PowerSourceKind: Equatable, Sendable {
    /// Wall power, including a UPS.
    case ac
    /// The Mac's internal battery.
    case battery
    /// The system reports no power source info.
    case none
}

/// Where the Mac draws power from. Seam for tests (test-plan 2.5).
@MainActor
protocol PowerSource: AnyObject {
    var current: PowerSourceKind { get }

    /// Calls `onChange` on the main actor whenever any power source changes
    /// (including battery percentage), for as long as the source is alive.
    func startObserving(_ onChange: @escaping @MainActor () -> Void)
}

/// Whether the Mac runs from its internal battery. Desktop Macs (no battery)
/// and Macs on a UPS report `false`. Feeds the battery warning (warn only,
/// This Mac segment; README Q2), which is shown by WP-31.
@MainActor
@Observable
final class PowerSourceMonitor {
    private(set) var isOnBattery: Bool

    @ObservationIgnored private let source: any PowerSource

    init(source: any PowerSource = IOKitPowerSource()) {
        self.source = source
        isOnBattery = source.current == .battery
        source.startObserving { [weak self] in self?.refresh() }
    }

    private func refresh() {
        let onBattery = source.current == .battery
        // IOKit also fires on every battery percentage change; log only real switches.
        guard onBattery != isOnBattery else { return }
        isOnBattery = onBattery
        NSLog("[Power] isOnBattery=%@", onBattery ? "true" : "false")
    }
}

/// Production source: IOKit power source snapshot plus a main run loop notification.
@MainActor
final class IOKitPowerSource: PowerSource {
    private var runLoopSource: CFRunLoopSource?
    private var onChange: (@MainActor () -> Void)?

    /// Nonisolated so it can be `PowerSourceMonitor.init`'s default argument.
    nonisolated init() {}

    var current: PowerSourceKind {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return .none }
        return Self.kind(providingType: IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?)
    }

    /// Maps `IOPSGetProvidingPowerSourceType` (`kIOPMACPowerKey`, `kIOPMBatteryPowerKey`,
    /// `kIOPMUPSPowerKey`) to a kind. A UPS counts as wall power.
    nonisolated static func kind(providingType: String?) -> PowerSourceKind {
        switch providingType {
        case kIOPMBatteryPowerKey: .battery
        case kIOPMACPowerKey, kIOPMUPSPowerKey: .ac
        default: .none
        }
    }

    func startObserving(_ onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
        guard runLoopSource == nil else { return }

        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let powerSource = Unmanaged<IOKitPowerSource>.fromOpaque(context).takeUnretainedValue()
            // The source is added to the main run loop, so this runs on the main thread.
            MainActor.assumeIsolated { powerSource.onChange?() }
        }, context)?.takeRetainedValue() else {
            NSLog("[Power] IOPSNotificationCreateRunLoopSource failed; power changes will not be observed")
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        runLoopSource = source
    }

    // Assumes release on the main thread (the owner is the main-actor
    // PowerSourceMonitor, held for the app's lifetime): the callback holds an
    // unretained pointer to self and also runs on the main thread, so removing
    // the source here cannot race with a callback in flight.
    deinit {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
    }
}
