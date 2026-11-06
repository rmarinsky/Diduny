@testable import Diduny
import Foundation
import Observation
import os
import Testing

/// Fake for the `PowerSource` seam (test-plan 2.5). Changes are driven by
/// `send(_:)`, which updates the reading and fires the handler synchronously,
/// the way the IOKit run loop source calls back on the main thread.
@MainActor
private final class FakePowerSource: PowerSource {
    var providingPowerSourceType: String?
    private(set) var isObserving = false
    private var onChange: (@MainActor () -> Void)?

    init(_ providingPowerSourceType: String?) {
        self.providingPowerSourceType = providingPowerSourceType
    }

    func startObserving(_ onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
        isObserving = true
    }

    func send(_ providingPowerSourceType: String?) {
        self.providingPowerSourceType = providingPowerSourceType
        onChange?()
    }
}

/// Values IOKit returns from `IOPSGetProvidingPowerSourceType`
/// (`kIOPMACPowerKey`, `kIOPMBatteryPowerKey`, `kIOPMUPSPowerKey`).
private enum IOPSType {
    static let ac = "AC Power"
    static let battery = "Battery Power"
    static let ups = "UPS Power"
}

/// True when `action` makes Observation report a change of `isOnBattery`.
/// `onChange` is called synchronously from the property's willSet.
@MainActor
private func notifiesObservers(_ monitor: PowerSourceMonitor, during action: () -> Void) -> Bool {
    let notified = OSAllocatedUnfairLock(initialState: false)
    withObservationTracking {
        _ = monitor.isOnBattery
    } onChange: {
        notified.withLock { $0 = true }
    }
    action()
    return notified.withLock { $0 }
}

@Suite("PowerSourceMonitor")
@MainActor
struct PowerSourceMonitorTests {
    @Test("A plugged-in MacBook is not on battery")
    func pluggedIn() {
        let monitor = PowerSourceMonitor(source: FakePowerSource(IOPSType.ac))
        #expect(monitor.isOnBattery == false)
    }

    @Test("A MacBook running from its battery is on battery")
    func onBattery() {
        let monitor = PowerSourceMonitor(source: FakePowerSource(IOPSType.battery))
        #expect(monitor.isOnBattery == true)
    }

    @Test(
        "A Mac without a battery reports not on battery",
        arguments: [nil, IOPSType.ac, IOPSType.ups] as [String?]
    )
    func desktopWithoutBattery(providingType: String?) {
        let monitor = PowerSourceMonitor(source: FakePowerSource(providingType))
        #expect(monitor.isOnBattery == false)
    }

    @Test("The monitor observes its source from the start")
    func startsObserving() {
        let source = FakePowerSource(IOPSType.ac)
        _ = PowerSourceMonitor(source: source)
        #expect(source.isObserving)
    }

    @Test("Unplugging updates isOnBattery and notifies observers")
    func pluggedToBatteryNotifies() {
        let source = FakePowerSource(IOPSType.ac)
        let monitor = PowerSourceMonitor(source: source)

        let notified = notifiesObservers(monitor) { source.send(IOPSType.battery) }

        #expect(notified)
        #expect(monitor.isOnBattery == true)
    }

    @Test("Plugging back in returns to not on battery")
    func batteryToPlugged() {
        let source = FakePowerSource(IOPSType.battery)
        let monitor = PowerSourceMonitor(source: source)

        source.send(IOPSType.ac)

        #expect(monitor.isOnBattery == false)
    }

    @Test("A power event that keeps the same source does not notify observers")
    func sameSourceDoesNotNotify() {
        // IOKit also fires on battery percentage changes; those must not re-render views.
        let source = FakePowerSource(IOPSType.battery)
        let monitor = PowerSourceMonitor(source: source)

        let notified = notifiesObservers(monitor) { source.send(IOPSType.battery) }

        #expect(notified == false)
        #expect(monitor.isOnBattery == true)
    }
}
