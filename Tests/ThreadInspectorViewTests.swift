import XCTest
@testable import BetterMail

final class ThreadInspectorViewTests: XCTestCase {
    func test_openInMailStatus_whenStateIsNil_returnsIdle() {
        let status = ThreadInspectorView.openInMailStatus(for: nil, messageID: "message-id")
        XCTAssertEqual(status, .idle)
    }

    func test_openInMailStatus_whenMessageIDDoesNotMatch_returnsIdle() {
        let state = OpenInMailState(messageID: "message-id",
                                    status: .searchingFilteredFallback)
        let status = ThreadInspectorView.openInMailStatus(for: state, messageID: "other-id")
        XCTAssertEqual(status, .idle)
    }

    func test_openInMailStatus_whenMessageIDMatches_returnsStateStatus() {
        let state = OpenInMailState(messageID: "message-id",
                                    status: .opened(.filteredFallback))
        let status = ThreadInspectorView.openInMailStatus(for: state, messageID: "message-id")
        XCTAssertEqual(status, .opened(.filteredFallback))
    }
}
