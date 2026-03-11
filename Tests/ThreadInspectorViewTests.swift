import XCTest
@testable import BetterMail

final class ThreadInspectorViewTests: XCTestCase {
    func test_openInMailStatus_whenStateIsNil_returnsIdle() {
        let status = ThreadInspectorView.openInMailStatus(for: nil, messageKey: "message-key")
        XCTAssertEqual(status, .idle)
    }

    func test_openInMailStatus_whenMessageKeyDoesNotMatch_returnsIdle() {
        let state = OpenInMailState(messageKey: "message-key",
                                    status: .searchingFilteredFallback)
        let status = ThreadInspectorView.openInMailStatus(for: state, messageKey: "other-key")
        XCTAssertEqual(status, .idle)
    }

    func test_openInMailStatus_whenMessageKeyMatches_returnsStateStatus() {
        let state = OpenInMailState(messageKey: "message-key",
                                    status: .opened(.filteredFallback))
        let status = ThreadInspectorView.openInMailStatus(for: state, messageKey: "message-key")
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
