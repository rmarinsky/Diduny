@testable import Diduny
import XCTest

@MainActor
final class OtherBuildLibraryTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("OtherBuildLibraryTests-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func snapshot(_ dir: URL) -> [String: Data] {
        let paths = FileManager.default.enumerator(atPath: dir.path)?.allObjects as? [String] ?? []
        return Dictionary(uniqueKeysWithValues: paths.compactMap { path in
            (try? Data(contentsOf: dir.appendingPathComponent(path))).map { (path, $0) }
        })
    }

    private func waitForOtherBuildRows(_ store: RecordingsLibraryStorage, count: Int) async throws {
        for _ in 0 ..< 200 where store.otherBuildRecordings.count != count {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(store.otherBuildRecordings.count, count)
    }

    func test_otherBuildRows_areListedPlayableAndNeverChanged() async throws {
        let prodDir = root.appendingPathComponent("prod")
        let prod = RecordingsLibraryStorage(baseDirectory: prodDir, audioCompressor: { $0 })
        let prodID = try XCTUnwrap(prod.saveRecording(audioData: Data([1, 2, 3]), type: .meeting, duration: 60,
                                                      transcriptionText: "prod meeting",
                                                      createdAt: Date(timeIntervalSince1970: 0), forceSave: true))
        let before = snapshot(prodDir)

        let dev = RecordingsLibraryStorage(baseDirectory: root.appendingPathComponent("dev"),
                                           audioCompressor: { $0 }, otherBuildDirectory: prodDir)
        let devID = try XCTUnwrap(dev.saveRecording(audioData: Data([4]), type: .voice, duration: 1, forceSave: true))
        try await waitForOtherBuildRows(dev, count: 1)

        // Mixed into one list, newest first; own rows stay editable.
        XCTAssertEqual(dev.libraryRecordings.map(\.id), [devID, prodID])
        XCTAssertTrue(dev.isOtherBuildRecording(prodID))
        XCTAssertFalse(dev.isOtherBuildRecording(devID))
        let prodRow = try XCTUnwrap(dev.libraryRecordings.first { $0.id == prodID })
        XCTAssertTrue(dev.audioFileURL(for: prodRow).path.hasPrefix(prodDir.path))
        XCTAssertTrue(dev.hasPlayableAudio(for: prodRow))

        // Deleting and retention from DEV do not reach production.
        _ = dev.deleteRecordings([prodID])
        dev.pruneExpiredRecordings(now: .distantFuture)
        dev.reloadOtherBuildLibrary()
        try await waitForOtherBuildRows(dev, count: 1)
        XCTAssertEqual(snapshot(prodDir), before)
    }

    func test_reader_skipsRowsItCannotDecode() throws {
        let dir = root.appendingPathComponent("prod")
        let prod = RecordingsLibraryStorage(baseDirectory: dir, audioCompressor: { $0 })
        _ = try XCTUnwrap(prod.saveRecording(audioData: Data([1]), type: .voice, duration: 1, forceSave: true))
        let url = dir.appendingPathComponent("recordings_metadata.json")
        var rows = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
        var future = rows[0]
        future["type"] = "typeFromANewerBuild"
        rows.append(future)
        try JSONSerialization.data(withJSONObject: rows).write(to: url)

        XCTAssertEqual(RecordingsLibraryStorage.readOtherBuildRecordings(from: url).count, 1)
    }
}
