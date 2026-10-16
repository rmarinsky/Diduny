import XCTest
@testable import Diduny
final class BrowserProfileTests: XCTestCase {
    func testOnlyListedSafeProfileDirectoriesAreReturnedWithoutAccountDetails() {
        let data = Data(#"{"profile":{"info_cache":{"Default":{"name":"Personal","user_name":"private@example.com"},"Profile 1":{"name":"Work"},"Guest":{"name":"Guest","is_omitted_from_profile_list":true},"../other":{"name":"Invalid"}}}}"#.utf8)
        XCTAssertEqual(BrowserProfile.chromium(data: data), [BrowserProfile(id: "Default", name: "Personal"), BrowserProfile(id: "Profile 1", name: "Work")])
        XCTAssertEqual(BrowserProfile.chromium(data: Data("bad".utf8)), [])
    }
}

extension BrowserProfileTests {
    func testNativeProfileMenuExcludesCommandsAndAmbiguousNames() {
        XCTAssertEqual(BrowserProfile.nativeMenu(items: [("Work", "switchToProfileFromMenu:"), ("Edit…", "editProfile:"), ("Personal", "switchToProfileFromMenu:")]), [BrowserProfile(id: "menu:Work", name: "Work"), BrowserProfile(id: "menu:Personal", name: "Personal")])
        XCTAssertEqual(BrowserProfile.nativeMenu(items: [("Work", "switchToProfileFromMenu:"), ("Work", "switchToProfileFromMenu:")]), [])
        XCTAssertEqual(BrowserProfile.observed(in: ["Back", "Roma", "Menu"], names: ["Roma", "Work"]), "Roma")
        XCTAssertEqual(BrowserProfile.observed(in: ["Work Profile"], names: ["Work"]), "Work")
        XCTAssertNil(BrowserProfile.observed(in: ["Work Profile", "Roma"], names: ["Work", "Roma"]))
        XCTAssertNil(BrowserProfile.observed(in: ["Work page"], names: ["Work"]))
    }
}

extension BrowserProfileTests {
    func testNavigationAndOtherButtonsCannotImpersonateTheProfileControl() {
        let controls = [("AXButton", "Back"), ("AXButton", "Roma"), ("AXPopUpButton", "Chrome")]
        XCTAssertEqual(BrowserProfile.avatar(in: controls, names: ["Roma", "Back"]), "Roma")
        XCTAssertNil(BrowserProfile.avatar(in: controls, names: ["Back"]))
        XCTAssertNil(BrowserProfile.avatar(in: [("AXButton", "Work Profile")], names: ["Work"]))
        XCTAssertEqual(BrowserProfile.avatar(in: [("AXButton", "Work Profile"), ("AXButton", "Settings and more"), ("AXButton", "Chat")], names: ["Work"]), "Work")
    }
}
