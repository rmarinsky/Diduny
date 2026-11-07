import XCTest

/// Test bridge and probe helpers (test-plan 2.7). The app must run with `--ui-testing-input-bridge`
/// and `--ui-testing-probe` (profile `P-STD`).
extension DidunyUITestCase {
    /// The probe's text; its value is the app state as JSON.
    var probeElement: XCUIElement {
        app.descendants(matching: .any)["probe.state"]
    }

    /// Decoded probe state.
    func probe(file: StaticString = #filePath, line: UInt = #line) -> [String: Any] {
        waitForElement(probeElement, file: file, line: line)
        let json = probeElement.value as? String ?? "{}"
        return (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
    }

    /// Posts `cmd` to the app and waits until the probe shows its sequence number.
    func bridge(_ cmd: String, _ args: [String: Any] = [:], file: StaticString = #filePath, line: UInt = #line) {
        bridgeSequence += 1
        var payload = args
        payload["cmd"] = cmd
        payload["seq"] = bridgeSequence
        let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name("ua.com.rmarinsky.diduny.test.bridge"),
            object: String(data: data, encoding: .utf8),
            userInfo: nil,
            deliverImmediately: true
        )
        waitForElement(probeElement, toMatch: "value CONTAINS '\"seq\":\(bridgeSequence),'", file: file, line: line)
    }
}
