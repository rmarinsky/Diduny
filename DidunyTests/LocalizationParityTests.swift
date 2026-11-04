import XCTest

/// en and uk Localizable.strings carry the same keys, the same placeholders and no empty values (AC 45, 48, 57).
final class LocalizationParityTests: XCTestCase {
    private func strings(_ language: String) throws -> [String: String] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Diduny/Resources/\(language).lproj/Localizable.strings")
        return try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String], "\(language) strings unreadable")
    }

    private func placeholders(_ text: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: #"%(\d+\$)?(lld|ld|lu|@|d|f|s)"#)
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range)
            .compactMap { Range($0.range(at: 2), in: text).map { String(text[$0]) } }
            .sorted()
    }

    func testKeySetsMatch() throws {
        let en = try strings("en")
        let uk = try strings("uk")
        XCTAssertEqual(Set(en.keys).subtracting(uk.keys), [], "missing in uk")
        XCTAssertEqual(Set(uk.keys).subtracting(en.keys), [], "missing in en")
    }

    func testPlaceholdersMatchAndValuesAreNonEmpty() throws {
        let en = try strings("en")
        let uk = try strings("uk")
        for (key, enValue) in en where !key.isEmpty {
            guard let ukValue = uk[key] else { continue }
            XCTAssertEqual(placeholders(enValue), placeholders(ukValue), key)
            XCTAssertFalse(enValue.trimmingCharacters(in: .whitespaces).isEmpty, "en: \(key)")
            XCTAssertFalse(ukValue.trimmingCharacters(in: .whitespaces).isEmpty, "uk: \(key)")
        }
    }
}
