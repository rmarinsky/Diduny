import Foundation
import XCTest

/// Generic HTTP stub for provider tests. Only sessions from `session()` use it.
/// State is static: suites call `reset()` in both setUp and tearDown, and must not run in parallel.
final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var responses: [(Int, String)] = []
    nonisolated(unsafe) static var requests: [URLRequest] = []
    nonisolated(unsafe) static var failWith: URLError?

    static func reset() { responses = []; requests = []; failWith = nil }

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with _: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        Self.requests.append(request)
        if let error = Self.failWith {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        let (status, body) = Self.responses.isEmpty ? (200, "{}") : Self.responses.removeFirst()
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

/// Polls `condition` until true or fails after `timeout`. Waits for a state, not for a fixed time.
func waitUntil(
    timeout: TimeInterval = 2,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ condition: () -> Bool
) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > deadline {
            XCTFail("timed out waiting for condition", file: file, line: line)
            return
        }
        await Task.yield()
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
}

/// Fake clock for injected `sleep:` closures: each sleep parks until the test calls `tick()`.
final class ManualTicker: @unchecked Sendable {
    private let lock = NSLock()
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var requested: [TimeInterval] = []

    var waiting: Int { lock.withLock { waiters.count } }
    var intervals: [TimeInterval] { lock.withLock { requested } }

    func sleep(_ interval: TimeInterval) async {
        await withCheckedContinuation { continuation in
            lock.withLock {
                requested.append(interval)
                waiters.append(continuation)
            }
        }
    }

    func tick() {
        let ready: [CheckedContinuation<Void, Never>] = lock.withLock {
            defer { waiters = [] }
            return waiters
        }
        ready.forEach { $0.resume() }
    }
}
