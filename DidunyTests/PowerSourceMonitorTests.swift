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
    var current: PowerSourceKind
    private var onChange: (@MainActor () -> Void)?

    init(_ current: PowerSourceKind) {
        self.current = current
    }

    func startObserving(_ onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
    }

    func send(_ kind: PowerSourceKind) {
        current = kind
        onChange?()
    }
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
    @Test("A MacBook running from its battery is on battery")
    func onBattery() {
        let monitor = PowerSourceMonitor(source: FakePowerSource(.battery))
        #expect(monitor.isOnBattery == true)
    }

    @Test(
        "A Mac on wall power or without power source info is not on battery",
        arguments: [PowerSourceKind.ac, .none]
    )
    func notOnBattery(kind: PowerSourceKind) {
        let monitor = PowerSourceMonitor(source: FakePowerSource(kind))
        #expect(monitor.isOnBattery == false)
    }

    @Test("Unplugging updates isOnBattery and notifies observers")
    func pluggedToBatteryNotifies() {
        let source = FakePowerSource(.ac)
        let monitor = PowerSourceMonitor(source: source)

        let notified = notifiesObservers(monitor) { source.send(.battery) }

        #expect(notified)
        #expect(monitor.isOnBattery == true)
    }

    @Test("Plugging back in returns to not on battery")
    func batteryToPlugged() {
        let source = FakePowerSource(.battery)
        let monitor = PowerSourceMonitor(source: source)

        source.send(.ac)

        #expect(monitor.isOnBattery == false)
    }

    @Test("A power event that keeps the same source does not notify observers")
    func sameSourceDoesNotNotify() {
        // IOKit also fires on battery percentage changes; those must not re-render views.
        let source = FakePowerSource(.battery)
        let monitor = PowerSourceMonitor(source: source)

        let notified = notifiesObservers(monitor) { source.send(.battery) }

        #expect(notified == false)
        #expect(monitor.isOnBattery == true)
    }

    @Test("The monitor is released while its source lives on (no strong self in the handler)")
    func monitorDeallocates() {
        let source = FakePowerSource(.ac)
        weak var weakMonitor: PowerSourceMonitor?
        do {
            let monitor = PowerSourceMonitor(source: source)
            weakMonitor = monitor
        }
        #expect(weakMonitor == nil)
    }

    @Test(
        "IOKit providing types map to a kind; a UPS counts as wall power",
        arguments: [
            ("Battery Power", PowerSourceKind.battery),
            ("AC Power", .ac),
            ("UPS Power", .ac),
            (nil, .none),
        ] as [(String?, PowerSourceKind)]
    )
    func ioKitMapping(providingType: String?, expected: PowerSourceKind) {
        #expect(IOKitPowerSource.kind(providingType: providingType) == expected)
    }

    @Test("The real IOKit source reads, observes and is released without crashing")
    func ioKitSourceSmoke() {
        // Hardware-independent: any kind is valid; the point is the IOKit calls and cleanup.
        var source: IOKitPowerSource? = IOKitPowerSource()
        let kinds: [PowerSourceKind] = [.ac, .battery, .none]
        #expect(kinds.contains(source!.current))
        #expect(kinds.contains(source!.current))
        source?.startObserving {}
        source = nil
        #expect(source == nil)
    }
}
