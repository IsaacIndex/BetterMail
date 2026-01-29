import XCTest
@testable import BetterMail

@MainActor
final class ThreadCanvasLayoutTests: XCTestCase {
    func testDayIndexForLastSevenDays() {
        let calendar = Calendar(identifier: .gregorian)
        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = TimeZone(secondsFromGMT: 0)
        components.year = 2025
        components.month = 3
        components.day = 8
        components.hour = 12
        let today = calendar.date(from: components)!

        let sameDay = today
        let threeDaysAgo = calendar.date(byAdding: .day, value: -3, to: today)!
        let eightDaysAgo = calendar.date(byAdding: .day, value: -8, to: today)!
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!

        let dayCount = ThreadCanvasLayoutMetrics.defaultDayCount
        XCTAssertEqual(ThreadCanvasDateHelper.dayIndex(for: sameDay,
                                                       today: today,
                                                       calendar: calendar,
                                                       dayCount: dayCount), 0)
        XCTAssertEqual(ThreadCanvasDateHelper.dayIndex(for: threeDaysAgo,
                                                       today: today,
                                                       calendar: calendar,
                                                       dayCount: dayCount), 3)
        XCTAssertNil(ThreadCanvasDateHelper.dayIndex(for: eightDaysAgo,
                                                     today: today,
                                                     calendar: calendar,
                                                     dayCount: dayCount))
        XCTAssertNil(ThreadCanvasDateHelper.dayIndex(for: tomorrow,
                                                     today: today,
                                                     calendar: calendar,
                                                     dayCount: dayCount))
    }

    func testColumnOrderingUsesLatestThreadActivity() {
        let calendar = Calendar(identifier: .gregorian)
        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = TimeZone(secondsFromGMT: 0)
        components.year = 2025
        components.month = 3
        components.day = 8
        components.hour = 9
        let today = calendar.date(from: components)!

        let olderRootMessage = EmailMessage(messageID: "root-older",
                                            mailboxID: "inbox",
                                            accountName: "",
                                            subject: "Older Thread",
                                            from: "a@example.com",
                                            to: "me@example.com",
                                            date: calendar.date(byAdding: .day, value: -5, to: today)!,
                                            snippet: "",
                                            isUnread: false,
                                            inReplyTo: nil,
                                            references: [],
                                            threadID: "thread-old")
        let newerChildMessage = EmailMessage(messageID: "child-newer",
                                             mailboxID: "inbox",
                                             accountName: "",
                                             subject: "Older Thread",
                                             from: "b@example.com",
                                             to: "me@example.com",
                                             date: calendar.date(byAdding: .day, value: -1, to: today)!,
                                             snippet: "",
                                             isUnread: false,
                                             inReplyTo: nil,
                                             references: [],
                                             threadID: "thread-old")
        let rootWithNewerChild = ThreadNode(message: olderRootMessage, children: [ThreadNode(message: newerChildMessage)])

        let newerRootMessage = EmailMessage(messageID: "root-newer",
                                            mailboxID: "inbox",
                                            accountName: "",
                                            subject: "Newer Thread",
                                            from: "c@example.com",
                                            to: "me@example.com",
                                            date: calendar.date(byAdding: .day, value: -2, to: today)!,
                                            snippet: "",
                                            isUnread: false,
                                            inReplyTo: nil,
                                            references: [],
                                            threadID: "thread-new")
        let newerRoot = ThreadNode(message: newerRootMessage)

        let metrics = ThreadCanvasLayoutMetrics(zoom: 1.0)
        let layout = ThreadCanvasViewModel.canvasLayout(for: [newerRoot, rootWithNewerChild],
                                                         metrics: metrics,
                                                         today: today,
                                                         calendar: calendar)

        XCTAssertEqual(layout.columns.first?.id, "thread-old")
        XCTAssertEqual(layout.columns.count, 2)
    }

    func testSelectionMappingFindsNestedNode() {
        let rootMessage = EmailMessage(messageID: "root",
                                       mailboxID: "inbox",
                                       accountName: "",
                                       subject: "Root",
                                       from: "a@example.com",
                                       to: "me@example.com",
                                       date: Date(),
                                       snippet: "",
                                       isUnread: false,
                                       inReplyTo: nil,
                                       references: [],
                                       threadID: "thread-root")
        let childMessage = EmailMessage(messageID: "child",
                                        mailboxID: "inbox",
                                        accountName: "",
                                        subject: "Child",
                                        from: "b@example.com",
                                        to: "me@example.com",
                                        date: Date(),
                                        snippet: "",
                                        isUnread: false,
                                        inReplyTo: nil,
                                        references: [],
                                        threadID: "thread-root")

        let root = ThreadNode(message: rootMessage, children: [ThreadNode(message: childMessage)])
        let match = ThreadCanvasViewModel.node(matching: "child", in: [root])
        let missing = ThreadCanvasViewModel.node(matching: "missing", in: [root])

        XCTAssertEqual(match?.id, "child")
        XCTAssertNil(missing)
    }

    func testManualOverrideUpdatesLatestDateOrdering() {
        let calendar = Calendar(identifier: .gregorian)
        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = TimeZone(secondsFromGMT: 0)
        components.year = 2025
        components.month = 3
        components.day = 8
        components.hour = 12
        let today = calendar.date(from: components)!

        let rootMessage = EmailMessage(messageID: "root-a",
                                       mailboxID: "inbox",
                                       accountName: "",
                                       subject: "Thread A",
                                       from: "a@example.com",
                                       to: "me@example.com",
                                       date: calendar.date(byAdding: .day, value: -5, to: today)!,
                                       snippet: "",
                                       isUnread: false,
                                       inReplyTo: nil,
                                       references: [])
        let threadBRoot = EmailMessage(messageID: "root-b",
                                       mailboxID: "inbox",
                                       accountName: "",
                                       subject: "Thread B",
                                       from: "b@example.com",
                                       to: "me@example.com",
                                       date: calendar.date(byAdding: .day, value: -3, to: today)!,
                                       snippet: "",
                                       isUnread: false,
                                       inReplyTo: nil,
                                       references: [])
        let threadBReply = EmailMessage(messageID: "reply-b",
                                        mailboxID: "inbox",
                                        accountName: "",
                                        subject: "Thread B",
                                        from: "c@example.com",
                                        to: "me@example.com",
                                        date: calendar.date(byAdding: .day, value: -1, to: today)!,
                                        snippet: "",
                                        isUnread: false,
                                        inReplyTo: threadBRoot.messageID,
                                        references: [])

        let threader = JWZThreader()
        let result = threader.buildThreads(from: [rootMessage, threadBRoot, threadBReply])
        let threadAID = result.jwzThreadMap[rootMessage.threadKey]!
        let threadBID = result.jwzThreadMap[threadBReply.threadKey]!
        let manualGroup = ManualThreadGroup(id: "manual-merge",
                                            jwzThreadIDs: [threadAID, threadBID],
                                            manualMessageKeys: [])
        let applied = threader.applyManualGroups([manualGroup], to: result)

        let metrics = ThreadCanvasLayoutMetrics(zoom: 1.0)
        let layout = ThreadCanvasViewModel.canvasLayout(for: applied.result.roots,
                                                        metrics: metrics,
                                                        today: today,
                                                        calendar: calendar,
                                                        manualAttachmentMessageIDs: applied.result.manualAttachmentMessageIDs,
                                                        jwzThreadMap: applied.result.jwzThreadMap)

        XCTAssertEqual(layout.columns.first?.id, manualGroup.id)
        XCTAssertEqual(layout.columns.count, 1)
    }

    func testMergedGroupPreservesJWZThreadIDsInLayout() {
        let calendar = Calendar(identifier: .gregorian)
        let baseDate = calendar.date(from: DateComponents(year: 2025, month: 3, day: 8, hour: 12))!

        let messageA = EmailMessage(messageID: "a1",
                                    mailboxID: "inbox",
                                    accountName: "",
                                    subject: "A",
                                    from: "a@example.com",
                                    to: "me@example.com",
                                    date: calendar.date(byAdding: .day, value: -2, to: baseDate)!,
                                    snippet: "",
                                    isUnread: false,
                                    inReplyTo: nil,
                                    references: [])
        let messageB = EmailMessage(messageID: "b1",
                                    mailboxID: "inbox",
                                    accountName: "",
                                    subject: "B",
                                    from: "b@example.com",
                                    to: "me@example.com",
                                    date: calendar.date(byAdding: .day, value: -1, to: baseDate)!,
                                    snippet: "",
                                    isUnread: false,
                                    inReplyTo: nil,
                                    references: [])

        let threader = JWZThreader()
        let result = threader.buildThreads(from: [messageA, messageB])
        let threadAID = result.jwzThreadMap[messageA.threadKey]!
        let threadBID = result.jwzThreadMap[messageB.threadKey]!

        let manualGroup = ManualThreadGroup(id: "manual-merge",
                                            jwzThreadIDs: [threadAID, threadBID],
                                            manualMessageKeys: [])
        let applied = threader.applyManualGroups([manualGroup], to: result)

        let metrics = ThreadCanvasLayoutMetrics(zoom: 1.0)
        let layout = ThreadCanvasViewModel.canvasLayout(for: applied.result.roots,
                                                        metrics: metrics,
                                                        today: baseDate,
                                                        calendar: calendar,
                                                        manualAttachmentMessageIDs: applied.result.manualAttachmentMessageIDs,
                                                        jwzThreadMap: applied.result.jwzThreadMap)

        let jwzIDs = Set(layout.columns.first?.nodes.map(\.jwzThreadID) ?? [])
        XCTAssertEqual(jwzIDs, Set([threadAID, threadBID]))
    }

    func testVisibleDayRangeFromScrollOffset() {
        let calendar = Calendar(identifier: .gregorian)
        let today = calendar.date(from: DateComponents(year: 2025, month: 3, day: 8, hour: 12))!
        let metrics = ThreadCanvasLayoutMetrics(zoom: 1.0)
        let layout = ThreadCanvasViewModel.canvasLayout(for: [],
                                                        metrics: metrics,
                                                        today: today,
                                                        calendar: calendar)

        let rangeAtTop = ThreadCanvasViewModel.visibleDayRange(for: layout,
                                                               scrollOffset: 0,
                                                               viewportHeight: metrics.dayHeight * 2)
        XCTAssertEqual(rangeAtTop, 0...1)

        let scrolledRange = ThreadCanvasViewModel.visibleDayRange(for: layout,
                                                                  scrollOffset: metrics.dayHeight * 2,
                                                                  viewportHeight: metrics.dayHeight * 1.5)
        XCTAssertEqual(scrolledRange, 1...3)
    }

    func testPagingThresholdDetection() {
        let shouldExpand = ThreadCanvasViewModel.shouldExpandDayWindow(scrollOffset: 880,
                                                                       viewportHeight: 200,
                                                                       contentHeight: 1100,
                                                                       threshold: 200)
        XCTAssertTrue(shouldExpand)

        let shouldNotExpand = ThreadCanvasViewModel.shouldExpandDayWindow(scrollOffset: 200,
                                                                          viewportHeight: 200,
                                                                          contentHeight: 1100,
                                                                          threshold: 200)
        XCTAssertFalse(shouldNotExpand)
    }

    func testFolderOrderingKeepsMembersAdjacentAndSortedByFolderLatestDate() {
        let calendar = Calendar(identifier: .gregorian)
        let today = calendar.date(from: DateComponents(year: 2025, month: 3, day: 8, hour: 12))!

        let threadA = EmailMessage(messageID: "a",
                                   mailboxID: "inbox",
                                   accountName: "",
                                   subject: "A",
                                   from: "a@example.com",
                                   to: "me@example.com",
                                   date: calendar.date(byAdding: .day, value: -3, to: today)!,
                                   snippet: "",
                                   isUnread: false,
                                   inReplyTo: nil,
                                   references: [],
                                   threadID: "thread-a")
        let threadB = EmailMessage(messageID: "b",
                                   mailboxID: "inbox",
                                   accountName: "",
                                   subject: "B",
                                   from: "b@example.com",
                                   to: "me@example.com",
                                   date: calendar.date(byAdding: .day, value: -1, to: today)!,
                                   snippet: "",
                                   isUnread: false,
                                   inReplyTo: nil,
                                   references: [],
                                   threadID: "thread-b")
        let threadC = EmailMessage(messageID: "c",
                                   mailboxID: "inbox",
                                   accountName: "",
                                   subject: "C",
                                   from: "c@example.com",
                                   to: "me@example.com",
                                   date: calendar.date(byAdding: .day, value: -2, to: today)!,
                                   snippet: "",
                                   isUnread: false,
                                   inReplyTo: nil,
                                   references: [],
                                   threadID: "thread-c")

        let roots = [
            ThreadNode(message: threadA),
            ThreadNode(message: threadB),
            ThreadNode(message: threadC)
        ]

        let folder = ThreadFolder(id: "folder-1",
                                  title: "Folder",
                                  color: ThreadFolderColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1),
                                  threadIDs: ["thread-a", "thread-b"],
                                  parentID: nil)
        let membership = ThreadCanvasViewModel.folderMembershipMap(for: [folder])

        let metrics = ThreadCanvasLayoutMetrics(zoom: 1.0)
        let layout = ThreadCanvasViewModel.canvasLayout(for: roots,
                                                        metrics: metrics,
                                                        today: today,
                                                        calendar: calendar,
                                                        folders: [folder],
                                                        folderMembershipByThreadID: membership)

        XCTAssertEqual(layout.columns.count, 3)
        XCTAssertEqual(layout.columns.prefix(2).map(\.id).sorted(), ["thread-a", "thread-b"])
        XCTAssertEqual(layout.columns.last?.id, "thread-c")
    }

    func testNestedFolderOrderingKeepsChildAdjacentToParent() {
        let calendar = Calendar(identifier: .gregorian)
        let today = calendar.date(from: DateComponents(year: 2025, month: 3, day: 8, hour: 12))!

        let childThread = EmailMessage(messageID: "child",
                                       mailboxID: "inbox",
                                       accountName: "",
                                       subject: "Child",
                                       from: "a@example.com",
                                       to: "me@example.com",
                                       date: calendar.date(byAdding: .day, value: -1, to: today)!,
                                       snippet: "",
                                       isUnread: false,
                                       inReplyTo: nil,
                                       references: [],
                                       threadID: "thread-child")
        let parentThread = EmailMessage(messageID: "parent",
                                        mailboxID: "inbox",
                                        accountName: "",
                                        subject: "Parent",
                                        from: "b@example.com",
                                        to: "me@example.com",
                                        date: calendar.date(byAdding: .day, value: -2, to: today)!,
                                        snippet: "",
                                        isUnread: false,
                                        inReplyTo: nil,
                                        references: [],
                                        threadID: "thread-parent")
        let externalThread = EmailMessage(messageID: "external",
                                          mailboxID: "inbox",
                                          accountName: "",
                                          subject: "External",
                                          from: "c@example.com",
                                          to: "me@example.com",
                                          date: calendar.date(byAdding: .day, value: -3, to: today)!,
                                          snippet: "",
                                          isUnread: false,
                                          inReplyTo: nil,
                                          references: [],
                                          threadID: "thread-external")

        let roots = [
            ThreadNode(message: childThread),
            ThreadNode(message: parentThread),
            ThreadNode(message: externalThread)
        ]

        let parentFolder = ThreadFolder(id: "folder-parent",
                                        title: "Parent",
                                        color: ThreadFolderColor(red: 0.4, green: 0.5, blue: 0.7, alpha: 1),
                                        threadIDs: ["thread-parent"],
                                        parentID: nil)
        let childFolder = ThreadFolder(id: "folder-child",
                                       title: "Child",
                                       color: ThreadFolderColor(red: 0.6, green: 0.7, blue: 0.8, alpha: 1),
                                       threadIDs: ["thread-child"],
                                       parentID: parentFolder.id)
        let folders = [parentFolder, childFolder]
        let membership = ThreadCanvasViewModel.folderMembershipMap(for: folders)

        let metrics = ThreadCanvasLayoutMetrics(zoom: 1.0)
        let layout = ThreadCanvasViewModel.canvasLayout(for: roots,
                                                        metrics: metrics,
                                                        today: today,
                                                        calendar: calendar,
                                                        folders: folders,
                                                        folderMembershipByThreadID: membership)

        XCTAssertEqual(layout.columns.count, 3)
        XCTAssertEqual(layout.columns.prefix(2).map(\.id), ["thread-child", "thread-parent"])
        XCTAssertEqual(layout.columns.last?.id, "thread-external")
    }

    func testApplyMoveTransfersMembershipAndKeepsMapUpdated() {
        let folderA = ThreadFolder(id: "folder-a",
                                   title: "A",
                                   color: ThreadFolderColor(red: 0.1, green: 0.2, blue: 0.3, alpha: 1),
                                   threadIDs: ["thread-1"],
                                   parentID: nil)
        let folderB = ThreadFolder(id: "folder-b",
                                   title: "B",
                                   color: ThreadFolderColor(red: 0.5, green: 0.4, blue: 0.3, alpha: 1),
                                   threadIDs: ["thread-2"],
                                   parentID: nil)

        let update = ThreadCanvasViewModel.applyMove(threadID: "thread-1",
                                                     toFolderID: "folder-b",
                                                     folders: [folderA, folderB])

        XCTAssertEqual(update?.folders.first(where: { $0.id == "folder-a" })?.threadIDs.contains("thread-1"), false)
        XCTAssertEqual(update?.folders.first(where: { $0.id == "folder-b" })?.threadIDs.contains("thread-1"), true)
        XCTAssertEqual(update?.membership["thread-1"], "folder-b")
    }

    func testApplyRemovalDeletesEmptyFolder() {
        let folder = ThreadFolder(id: "folder-a",
                                  title: "A",
                                  color: ThreadFolderColor(red: 0.2, green: 0.3, blue: 0.4, alpha: 1),
                                  threadIDs: ["thread-1"],
                                  parentID: nil)

        let update = ThreadCanvasViewModel.applyRemoval(threadID: "thread-1",
                                                        folders: [folder])

        XCTAssertEqual(update?.remainingFolders.isEmpty, true)
        XCTAssertEqual(update?.deletedFolderIDs, ["folder-a"])
        XCTAssertNil(update?.membership["thread-1"])
    }

    func testApplyRemovalKeepsFolderWithChild() {
        let parentFolder = ThreadFolder(id: "folder-parent",
                                        title: "Parent",
                                        color: ThreadFolderColor(red: 0.2, green: 0.3, blue: 0.4, alpha: 1),
                                        threadIDs: ["thread-parent"],
                                        parentID: nil)
        let childFolder = ThreadFolder(id: "folder-child",
                                       title: "Child",
                                       color: ThreadFolderColor(red: 0.4, green: 0.5, blue: 0.6, alpha: 1),
                                       threadIDs: ["thread-child"],
                                       parentID: parentFolder.id)

        let update = ThreadCanvasViewModel.applyRemoval(threadID: "thread-parent",
                                                        folders: [parentFolder, childFolder])

        XCTAssertEqual(update?.deletedFolderIDs.isEmpty, true)
        XCTAssertEqual(update?.remainingFolders.contains(where: { $0.id == parentFolder.id }), true)
        XCTAssertEqual(update?.membership["thread-child"], childFolder.id)
    }

    func testTimelineNodesOrderedWithinVisibleWindow() {
        let calendar = Calendar(identifier: .gregorian)
        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = TimeZone(secondsFromGMT: 0)
        components.year = 2025
        components.month = 3
        components.day = 8
        components.hour = 9
        let today = calendar.date(from: components)!

        let newestMessage = EmailMessage(messageID: "newest",
                                         mailboxID: "inbox",
                                         accountName: "",
                                         subject: "Newest",
                                         from: "a@example.com",
                                         to: "me@example.com",
                                         date: calendar.date(byAdding: .hour, value: 1, to: today)!,
                                         snippet: "",
                                         isUnread: false,
                                         inReplyTo: nil,
                                         references: [])
        let olderMessage = EmailMessage(messageID: "older",
                                        mailboxID: "inbox",
                                        accountName: "",
                                        subject: "Older",
                                        from: "b@example.com",
                                        to: "me@example.com",
                                        date: calendar.date(byAdding: .day, value: -1, to: today)!,
                                        snippet: "",
                                        isUnread: false,
                                        inReplyTo: nil,
                                        references: [])
        let outsideWindowMessage = EmailMessage(messageID: "outside",
                                                mailboxID: "inbox",
                                                accountName: "",
                                                subject: "Outside",
                                                from: "c@example.com",
                                                to: "me@example.com",
                                                date: calendar.date(byAdding: .day, value: -4, to: today)!,
                                                snippet: "",
                                                isUnread: false,
                                                inReplyTo: nil,
                                                references: [])

        let roots = [
            ThreadNode(message: olderMessage),
            ThreadNode(message: outsideWindowMessage),
            ThreadNode(message: newestMessage)
        ]
        let timelineNodes = ThreadCanvasViewModel.timelineNodes(for: roots,
                                                                dayWindowCount: 2,
                                                                today: today,
                                                                calendar: calendar)

        XCTAssertEqual(timelineNodes.map(\.id), [newestMessage.messageID, olderMessage.messageID])
    }

    @MainActor
    func testTimelineTagsRequestedOncePerNode() async {
        let expectation = XCTestExpectation(description: "Tag request")
        let provider = TestTagProvider(tags: ["Urgent"], expectation: expectation)
        let capability = EmailTagCapability(provider: provider,
                                            statusMessage: "Ready",
                                            providerID: "test")
        let settings = AutoRefreshSettings()
        let inspectorSettings = InspectorViewSettings()
        let viewModel = ThreadCanvasViewModel(settings: settings,
                                              inspectorSettings: inspectorSettings,
                                              tagCapability: capability)

        let message = EmailMessage(messageID: "node-1",
                                   mailboxID: "inbox",
                                   accountName: "",
                                   subject: "Subject",
                                   from: "sender@example.com",
                                   to: "me@example.com",
                                   date: Date(timeIntervalSince1970: 1_700_000_000),
                                   snippet: "Snippet",
                                   isUnread: false,
                                   inReplyTo: nil,
                                   references: [])
        let node = ThreadNode(message: message)

        viewModel.requestTimelineTagsIfNeeded(for: node)
        viewModel.requestTimelineTagsIfNeeded(for: node)

        await fulfillment(of: [expectation], timeout: 1.0)

        for _ in 0..<20 {
            if viewModel.timelineTags(for: node.id) == ["Urgent"] {
                break
            }
            await Task.sleep(nanoseconds: 20_000_000)
        }

        XCTAssertEqual(provider.callCount, 1)
        XCTAssertEqual(viewModel.timelineTags(for: node.id), ["Urgent"])
    }
}

private final class TestTagProvider: EmailTagProviding {
    private let tags: [String]
    private let expectation: XCTestExpectation?
    private(set) var callCount: Int = 0

    init(tags: [String], expectation: XCTestExpectation? = nil) {
        self.tags = tags
        self.expectation = expectation
    }

    func generateTags(_ request: EmailTagRequest) async throws -> [String] {
        callCount += 1
        expectation?.fulfill()
        return tags
    }
}
