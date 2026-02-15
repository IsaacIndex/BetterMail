import SwiftUI
import XCTest
@testable import BetterMail

final class AppearanceSettingsTests: XCTestCase {
    func test_resolvedMode_whenStoredValueIsUnknown_returnsSystem() {
        let mode = AppAppearanceMode.resolvedMode(from: "sepia")
        XCTAssertEqual(mode, .system)
    }

    func test_resolvedMode_whenStoredValueIsKnown_returnsMatchingMode() {
        let mode = AppAppearanceMode.resolvedMode(from: "dark")
        XCTAssertEqual(mode, .dark)
    }

    func test_preferredColorScheme_whenModeIsSystem_returnsNil() {
        XCTAssertNil(AppAppearanceMode.system.preferredColorScheme)
    }

    func test_preferredColorScheme_whenModeIsLight_returnsLight() {
        XCTAssertEqual(AppAppearanceMode.light.preferredColorScheme, .light)
    }

    func test_preferredColorScheme_whenModeIsDark_returnsDark() {
        XCTAssertEqual(AppAppearanceMode.dark.preferredColorScheme, .dark)
    }
}
