import XCTest
@testable import Diduny

/// Tests for the RLR-M0 data-model additions:
///   - `RecoverySource` enum + `Recording.recoverySource` property
///   - `Recording.ProcessingStatus.partiallyRecovered` case
///
/// The primary concerns are:
///   1. Backward compatibility — JSON written before M0 (no `recoverySource` key,
///      no `partiallyRecovered` status) must decode without error.
///   2. Round-trip fidelity for the new fields.
///   3. Exhaustive switch coverage for `ProcessingStatus` (compiler-enforced).
final class RecordingModelMigrationTests: XCTestCase {

    // MARK: - Helpers

    private let iso8601: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private let iso8601Encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    // A minimal JSON object that represents a Recording saved before RLR-M0.
    // It intentionally omits `recoverySource` and uses only pre-M0 status values.
    private let legacyJSON = """
    [
      {
        "id": "12345678-1234-1234-1234-123456789ABC",
        "createdAt": "2025-11-01T10:00:00Z",
        "type": "meeting",
        "audioFileName": "12345678-1234-1234-1234-123456789ABC.wav",
        "durationSeconds": 3600.0,
        "fileSizeBytes": 675000000,
        "status": "transcribed",
        "transcriptionText": "Hello world.",
        "processedAt": "2025-11-01T11:00:00Z"
      }
    ]
    """

    // MARK: - 1. Backward compatibility

    func test_legacyJSON_decodesWithoutError() throws {
        let data = try XCTUnwrap(legacyJSON.data(using: .utf8))
        let recordings = try iso8601.decode([Recording].self, from: data)
        XCTAssertEqual(recordings.count, 1)
    }

    func test_legacyJSON_recoverySourceIsNil() throws {
        let data = try XCTUnwrap(legacyJSON.data(using: .utf8))
        let recordings = try iso8601.decode([Recording].self, from: data)
        XCTAssertNil(recordings[0].recoverySource,
                     "recordings from before M0 must have recoverySource == nil")
    }

    func test_legacyJSON_originalFieldsIntact() throws {
        let data = try XCTUnwrap(legacyJSON.data(using: .utf8))
        let r = try iso8601.decode([Recording].self, from: data)[0]

        XCTAssertEqual(r.id.uuidString, "12345678-1234-1234-1234-123456789ABC")
        XCTAssertEqual(r.type, .meeting)
        XCTAssertEqual(r.audioFileName, "12345678-1234-1234-1234-123456789ABC.wav")
        XCTAssertEqual(r.durationSeconds, 3600.0, accuracy: 0.001)
        XCTAssertEqual(r.fileSizeBytes, 675_000_000)
        XCTAssertEqual(r.status, .transcribed)
        XCTAssertEqual(r.transcriptionText, "Hello world.")
    }

    // MARK: - 2. Round-trip

    func test_roundTrip_orphanedSession_partiallyRecovered() throws {
        let original = Recording(
            id: UUID(uuidString: "AABBCCDD-AABB-CCDD-AABB-CCDDAABBCCDD")!,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            type: .meeting,
            audioFileName: "AABBCCDD-AABB-CCDD-AABB-CCDDAABBCCDD.flac",
            durationSeconds: 2400.0,
            fileSizeBytes: 48_000_000,
            status: .partiallyRecovered,
            transcriptionText: nil,
            errorMessage: nil,
            processedAt: nil,
            chapters: nil,
            sourceDevice: nil,
            recoverySource: .orphanedSession
        )

        let data = try iso8601Encoder.encode([original])
        let decoded = try iso8601.decode([Recording].self, from: data)[0]

        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.status, .partiallyRecovered)
        XCTAssertEqual(decoded.recoverySource, .orphanedSession)
        XCTAssertEqual(decoded.durationSeconds, original.durationSeconds, accuracy: 0.001)
        XCTAssertNil(decoded.transcriptionText)
    }

    func test_roundTrip_nilRecoverySource_normalStop() throws {
        let original = Recording(
            id: UUID(),
            createdAt: Date(timeIntervalSince1970: 1_700_100_000),
            type: .voice,
            audioFileName: "voice.wav",
            durationSeconds: 12.5,
            fileSizeBytes: 220_500,
            status: .transcribed,
            transcriptionText: "Test text.",
            errorMessage: nil,
            processedAt: Date(timeIntervalSince1970: 1_700_100_015),
            chapters: nil,
            sourceDevice: nil,
            recoverySource: nil
        )

        let data = try iso8601Encoder.encode([original])
        let decoded = try iso8601.decode([Recording].self, from: data)[0]

        XCTAssertEqual(decoded.status, .transcribed)
        XCTAssertNil(decoded.recoverySource)
    }

    // MARK: - 3. Exhaustive switch coverage (compiler-enforced)

    /// This test's body must enumerate every `ProcessingStatus` case.
    /// If a future PR adds a case without updating this switch the compiler
    /// will fail the build — that is the intended behavior.
    func test_processingStatus_switchIsExhaustive() {
        let allCases: [Recording.ProcessingStatus] = [
            .unprocessed,
            .processing,
            .transcribed,
            .translated,
            .failed,
            .partiallyRecovered,
        ]

        for status in allCases {
            switch status {
            case .unprocessed:
                _ = status
            case .processing:
                _ = status
            case .transcribed:
                _ = status
            case .translated:
                _ = status
            case .failed:
                _ = status
            case .partiallyRecovered:
                _ = status
            }
        }
        // If this compiles, all cases are handled.
        XCTAssertEqual(allCases.count, 6)
    }

    // MARK: - 4. RecoverySource raw-value stability

    func test_recoverySource_rawValues() {
        // Raw-value strings are persisted to disk — must never change.
        XCTAssertEqual(RecoverySource.orphanedSession.rawValue, "orphanedSession")
    }
}
