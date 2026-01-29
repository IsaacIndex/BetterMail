import XCTest
@testable import BetterMail

final class ThreadCanvasNodeTextVisibilityTests: XCTestCase {
    func testNodeTextVisibility_CompactMode_HidesSecondaryLines() {
        XCTAssertEqual(nodeTextVisibility(readabilityMode: .compact, isTitleLine: true), .normal)
        XCTAssertEqual(nodeTextVisibility(readabilityMode: .compact, isTitleLine: false), .hidden)
    }

    func testNodeTextVisibility_DetailedAndMinimalModes() {
        XCTAssertEqual(nodeTextVisibility(readabilityMode: .detailed, isTitleLine: false), .normal)
        XCTAssertEqual(nodeTextVisibility(readabilityMode: .minimal, isTitleLine: true), .hidden)
        XCTAssertEqual(nodeTextVisibility(readabilityMode: .minimal, isTitleLine: false), .hidden)
    }
}
