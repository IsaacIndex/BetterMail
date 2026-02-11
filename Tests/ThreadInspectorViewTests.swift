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

    func test_folderMinimapSurface_normalizedPoint_clampsIntoUnitSpace() {
        let point = FolderMinimapSurface.normalizedPoint(CGPoint(x: 260, y: -10),
                                                         in: CGSize(width: 200, height: 100))
        XCTAssertEqual(point.x, 1)
        XCTAssertEqual(point.y, 0)
    }

    func test_threadFolderInspectorView_minimapHeight_hasFixedNonScrollableSectionHeight() {
        XCTAssertEqual(ThreadFolderInspectorView.minimapHeight, 160)
    }
}
