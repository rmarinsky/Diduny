import BrowserDataAccess
import Foundation
import XCTest

final class BrowserDataAccessTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BrowserDataAccessTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try? FileManager.default.removeItem(at: directory)
    }

    func test_readableFile() throws {
        let file = directory.appendingPathComponent("Local State")
        try Data("{}".utf8).write(to: file)
        XCTAssertEqual(BrowserDataAccess.status(of: file), .readable)
    }

    func test_missingFile() {
        XCTAssertEqual(BrowserDataAccess.status(of: directory.appendingPathComponent("Local State")), .missing)
    }

    func test_unreadableFileIsBlocked() throws {
        let file = directory.appendingPathComponent("Local State")
        try Data("{}".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
        XCTAssertEqual(BrowserDataAccess.status(of: file), .blocked)
    }

    func test_privacySettingsOpensFullDiskAccess() {
        XCTAssertEqual(
            BrowserDataAccess.privacySettingsURL.absoluteString,
            "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
        )
    }
}
