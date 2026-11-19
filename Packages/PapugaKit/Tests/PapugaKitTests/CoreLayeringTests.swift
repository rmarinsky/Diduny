import XCTest

/// `Sources/PapugaKit/Core/` is the pure layer of the single `PapugaKit` module. The compiler no
/// longer separates it from `Engine/`, so this test keeps the layering honest.
final class CoreLayeringTests: XCTestCase {
    func test_coreFilesImportOnlyPureFrameworks() throws {
        let allowed: Set<String> = ["Foundation", "NaturalLanguage", "Carbon.HIToolbox"]
        let core = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // PapugaKitTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // PapugaKit package root
            .appendingPathComponent("Sources/PapugaKit/Core", isDirectory: true)
        let files = try XCTUnwrap(FileManager.default.enumerator(at: core, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
        XCTAssertFalse(files.isEmpty, "no Swift files found under \(core.path)")

        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            for line in source.split(separator: "\n") {
                let words = line.split(whereSeparator: \.isWhitespace).map(String.init)
                guard let importIndex = words.firstIndex(of: "import"),
                      words[..<importIndex].allSatisfy({ $0.hasPrefix("@") }),
                      let module = words.last, words.count > importIndex + 1 else { continue }
                XCTAssertTrue(
                    allowed.contains(module),
                    "\(file.lastPathComponent) imports \(module); Core may import only \(allowed.sorted())"
                )
            }
        }
    }
}
