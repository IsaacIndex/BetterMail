import XCTest
@testable import BetterMail

@MainActor
final class MailboxThreadAutoMoveSettingsTests: XCTestCase {
    private let storageKey = "mailboxThreadAutoMoveRules"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: storageKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: storageKey)
        super.tearDown()
    }

    func test_upsert_insertsAndUpdatesCompositeKey() {
        let settings = MailboxThreadAutoMoveSettings()

        settings.upsert(threadIDs: ["thread-1"],
                        destinationPath: "Projects/Acme",
                        account: "Work")
        settings.upsert(threadIDs: ["thread-1", "thread-2"],
                        destinationPath: "Clients/Globex",
                        account: "Work")

        XCTAssertEqual(settings.rules.count, 2)
        let byThread = Dictionary(uniqueKeysWithValues: settings.rules.map { ($0.threadID, $0) })
        XCTAssertEqual(byThread["thread-1"]?.destinationPath, "Clients/Globex")
        XCTAssertEqual(byThread["thread-2"]?.destinationPath, "Clients/Globex")
    }

    func test_upsert_keepsRulesSeparatedByAccount() {
        let settings = MailboxThreadAutoMoveSettings()

        settings.upsert(threadIDs: ["thread-1"],
                        destinationPath: "Projects/Acme",
                        account: "Work")
        settings.upsert(threadIDs: ["thread-1"],
                        destinationPath: "Archive",
                        account: "Personal")

        XCTAssertEqual(settings.rules.count, 2)
        XCTAssertTrue(settings.rules.contains(where: {
            $0.account == "Work" && $0.threadID == "thread-1" && $0.destinationPath == "Projects/Acme"
        }))
        XCTAssertTrue(settings.rules.contains(where: {
            $0.account == "Personal" && $0.threadID == "thread-1" && $0.destinationPath == "Archive"
        }))
    }
}
