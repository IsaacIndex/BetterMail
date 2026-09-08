import XCTest
@testable import BetterMail

final class OrganizerSuggestionPresentationTests: XCTestCase {
    func testActionPolicy_pendingProposalSupportsEditApproveRejectAndHide() {
        XCTAssertEqual(
            OrganizerSuggestionActionPolicy.actions(status: .pendingReview,
                                                      hasMutationDelta: false),
            [.edit, .approve, .reject, .hide]
        )
    }

    func testActionPolicy_failedCommittedProposalSupportsRetryUndoAndHide() {
        XCTAssertEqual(
            OrganizerSuggestionActionPolicy.actions(status: .failed,
                                                      hasMutationDelta: true),
            [.retry, .undo, .hide]
        )
    }

    func testActionPolicy_inFlightProposalCannotBeApprovedOrRetried() {
        XCTAssertEqual(
            OrganizerSuggestionActionPolicy.actions(status: .applying,
                                                      hasMutationDelta: false),
            [.hide]
        )
    }
}
