import CoreGraphics

/// Copied from the top of Papuga `Core/AutoFixController.swift`; the validator tags its own events with it.
enum PapugaSyntheticEvent {
    private static let marker: Int64 = 0x504150554741

    static func tag(_ event: CGEvent?) {
        event?.setIntegerValueField(.eventSourceUserData, value: marker)
    }

    static func isTagged(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.eventSourceUserData) == marker
    }
}
