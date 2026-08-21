import XCTest
@testable import BetterMail

final class ThreadInspectorViewTests: XCTestCase {
    func test_displayedGeneratedGraphTitle_whenTitleContainsContent_returnsTrimmedTitle() {
        XCTAssertEqual(ThreadInspectorView.displayedGeneratedGraphTitle("  HKJC CRC Review Materials CR#60  "),
                       "HKJC CRC Review Materials CR#60")
    }

    func test_displayedGeneratedGraphTitle_whenTitleIsEmpty_returnsNil() {
        XCTAssertNil(ThreadInspectorView.displayedGeneratedGraphTitle(" \n "))
    }

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

    func test_inspectorEmailAddressParser_quotedCommas_keepNamesAndEmailsTogether() {
        let addresses = InspectorEmailAddressParser.parse(
            "\"Cheung, Simon\" <simon.cheung@hkjc.org.hk>, \"Chen, Rachel Q\"<rachel.q.chen@hkjc.org.hk>, steven.z.li@hkjc.org.hk"
        )

        XCTAssertEqual(addresses, [
            InspectorEmailAddress(displayName: "Cheung, Simon",
                                  email: "simon.cheung@hkjc.org.hk"),
            InspectorEmailAddress(displayName: "Chen, Rachel Q",
                                  email: "rachel.q.chen@hkjc.org.hk"),
            InspectorEmailAddress(displayName: nil,
                                  email: "steven.z.li@hkjc.org.hk")
        ])
    }

    func test_inspectorEmailAddressParser_groupAndFoldedHeader_returnsIndividualRecipients() {
        let addresses = InspectorEmailAddressParser.parse(
            "Reviewers: Doris FUNG <doris.fung@hk1.ibm.com>,\r\n Simon <simon@example.com>; Junjie LIN <junjie@example.com>"
        )

        XCTAssertEqual(addresses.map(\.primaryText), ["Doris FUNG", "Simon", "Junjie LIN"])
        XCTAssertEqual(addresses.compactMap(\.email), [
            "doris.fung@hk1.ibm.com",
            "simon@example.com",
            "junjie@example.com"
        ])
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
