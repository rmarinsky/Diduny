@testable import Diduny
import XCTest

final class RemoteDeletionQueueTests: XCTestCase {
    private actor FakeDeleter: RemoteTranscriptDeleter {
        var results: [RemoteDeleteResult]
        private(set) var calls: [String] = []
        init(_ results: [RemoteDeleteResult]) { self.results = results }
        func deleteTranscript(remoteID: String, apiKey _: String) async -> RemoteDeleteResult {
            calls.append(remoteID)
            return results.isEmpty ? .deleted : results.removeFirst()
        }
    }

    private final class Box<T>: @unchecked Sendable {
        var value: T
        init(_ value: T) { self.value = value }
    }

    private let provider = "elevenlabs"
    private let sentinel = "sk_TEST_SENTINEL_0123456789"
    private var fileURL: URL!
    private var clock: Box<Date>!
    private var key: Box<String?>!
    private var notices: Box<[String]>!

    override func setUp() {
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("rdq-\(UUID().uuidString)")
            .appendingPathComponent("queue.json")
        clock = Box(Date(timeIntervalSince1970: 1_000_000))
        key = Box(sentinel)
        notices = Box([])
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
    }

    private func makeQueue(_ deleter: FakeDeleter) -> RemoteDeletionQueue {
        let clock = clock!, key = key!, notices = notices!
        return RemoteDeletionQueue(
            fileURL: fileURL,
            deleters: [provider: deleter],
            apiKey: { _ in key.value },
            now: { clock.value },
            onAuthFailure: { notices.value.append($0) }
        )
    }

    func test_persistedRecordHoldsOnlyIdsAndNoKey() async throws {
        let queue = makeQueue(FakeDeleter([]))
        await queue.enqueue(providerID: provider, remoteID: "tx_1")
        let text = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertTrue(text.contains("tx_1"))
        XCTAssertFalse(text.contains(sentinel))
        let keys = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [[String: Any]]).first?.keys
        XCTAssertEqual(Set(keys ?? [:].keys), ["providerID", "remoteID", "attempts", "nextAttemptAt"])
    }

    func test_deletedAndNotFoundRemoveEntry() async {
        let deleter = FakeDeleter([.deleted, .notFound])
        let queue = makeQueue(deleter)
        await queue.enqueue(providerID: provider, remoteID: "a")
        await queue.enqueue(providerID: provider, remoteID: "b")
        await queue.process()
        let pending = await queue.pending
        XCTAssertTrue(pending.isEmpty)
    }

    func test_retryLaterKeepsEntryWithBackoff() async {
        let deleter = FakeDeleter([.retryLater, .retryLater])
        let queue = makeQueue(deleter)
        await queue.enqueue(providerID: provider, remoteID: "a")
        await queue.process()
        var entry = await queue.pending.first
        XCTAssertEqual(entry?.attempts, 1)
        XCTAssertEqual(entry?.nextAttemptAt, clock.value.addingTimeInterval(5))
        await queue.process() // not due yet
        let callsBefore = await deleter.calls.count
        XCTAssertEqual(callsBefore, 1)
        clock.value = clock.value.addingTimeInterval(5)
        await queue.process()
        entry = await queue.pending.first
        XCTAssertEqual(entry?.attempts, 2)
        XCTAssertEqual(entry?.nextAttemptAt, clock.value.addingTimeInterval(10))
    }

    func test_unauthorizedDropsEntryAndNotifiesOnce() async {
        let queue = makeQueue(FakeDeleter([.unauthorized, .unauthorized]))
        await queue.enqueue(providerID: provider, remoteID: "a")
        await queue.enqueue(providerID: provider, remoteID: "b")
        await queue.process()
        let pending = await queue.pending
        XCTAssertTrue(pending.isEmpty)
        XCTAssertEqual(notices.value, [provider])
    }

    func test_relaunchRetriesPendingDeletes() async {
        let first = makeQueue(FakeDeleter([.retryLater]))
        await first.enqueue(providerID: provider, remoteID: "a")
        await first.process()
        clock.value = clock.value.addingTimeInterval(60)
        let deleter = FakeDeleter([.deleted])
        let relaunched = makeQueue(deleter)
        let restored = await relaunched.pending.count
        XCTAssertEqual(restored, 1)
        await relaunched.process()
        let pending = await relaunched.pending
        XCTAssertTrue(pending.isEmpty)
    }

    func test_duplicateIdsAreDeduplicated() async {
        let queue = makeQueue(FakeDeleter([]))
        await queue.enqueue(providerID: provider, remoteID: "a")
        await queue.enqueue(providerID: provider, remoteID: "a")
        let count = await queue.pending.count
        XCTAssertEqual(count, 1)
    }

    func test_keyRemovalKeepsEntries_savingKeyRetries() async {
        let deleter = FakeDeleter([.deleted])
        let queue = makeQueue(deleter)
        await queue.enqueue(providerID: provider, remoteID: "a")
        key.value = nil
        await queue.process()
        let calls = await deleter.calls
        XCTAssertTrue(calls.isEmpty)
        let kept = await queue.pending.count
        XCTAssertEqual(kept, 1)
        key.value = sentinel
        await queue.process()
        let pending = await queue.pending
        XCTAssertTrue(pending.isEmpty)
    }

    func test_corruptFileStartsEmpty() async throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: fileURL)
        let pending = await makeQueue(FakeDeleter([])).pending
        XCTAssertTrue(pending.isEmpty)
    }
}
