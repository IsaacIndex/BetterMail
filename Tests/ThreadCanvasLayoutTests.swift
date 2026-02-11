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

    func test_planJumpExpansionTargets_shortHistory_returnsNoStepsAndReached() {
        let plan = ThreadCanvasViewModel.planJumpExpansionTargets(currentDayCount: 21,
                                                                  requiredDayCount: 7,
                                                                  dayWindowIncrement: 7,
                                                                  maxDayCount: 365,
                                                                  maxSteps: 10)

        XCTAssertEqual(plan.targets, [])
        XCTAssertTrue(plan.reachedRequiredDayCount)
        XCTAssertEqual(plan.cappedDayCount, 21)
        XCTAssertEqual(plan.requiredDayCount, 21)
    }

    func test_planJumpExpansionTargets_veryLongHistory_respectsCapAndReportsUnreached() {
        let plan = ThreadCanvasViewModel.planJumpExpansionTargets(currentDayCount: 7,
                                                                  requiredDayCount: 9_999,
                                                                  dayWindowIncrement: 7,
                                                                  maxDayCount: 365,
                                                                  maxSteps: 50)

        XCTAssertFalse(plan.targets.isEmpty)
        XCTAssertEqual(plan.cappedDayCount, 365)
        XCTAssertFalse(plan.reachedRequiredDayCount)
        XCTAssertEqual(plan.requiredDayCount, 9_999)
    }

    func test_folderThreadIDsByFolder_nestedFolders_includeChildThreadsInParentScope() {
        let parent = ThreadFolder(id: "parent",
                                  title: "Parent",
                                  color: ThreadFolderColor(red: 0.2, green: 0.4, blue: 0.7, alpha: 1),
                                  threadIDs: ["thread-parent"],
                                  parentID: nil)
        let child = ThreadFolder(id: "child",
                                 title: "Child",
                                 color: ThreadFolderColor(red: 0.2, green: 0.7, blue: 0.4, alpha: 1),
                                 threadIDs: ["thread-child"],
                                 parentID: "parent")
        let sibling = ThreadFolder(id: "sibling",
                                   title: "Sibling",
                                   color: ThreadFolderColor(red: 0.9, green: 0.4, blue: 0.2, alpha: 1),
                                   threadIDs: ["thread-sibling"],
                                   parentID: nil)

        let map = ThreadCanvasViewModel.folderThreadIDsByFolder(folders: [parent, child, sibling])

        XCTAssertEqual(map["child"], Set(["thread-child"]))
        XCTAssertEqual(map["parent"], Set(["thread-parent", "thread-child"]))
        XCTAssertEqual(map["sibling"], Set(["thread-sibling"]))
    }

    func test_boundaryNodeID_tieBreakers_selectDeterministicOldestAndNewest() {
        let calendar = Calendar(identifier: .gregorian)
        let baseDate = calendar.date(from: DateComponents(year: 2025, month: 3, day: 8, hour: 12))!
        let olderDate = calendar.date(byAdding: .day, value: -2, to: baseDate)!
        let newerDate = calendar.date(byAdding: .day, value: -1, to: baseDate)!

        let oldA = ThreadNode(message: makeMessage(id: "a-old", date: olderDate))
        let oldB = ThreadNode(message: makeMessage(id: "z-old", date: olderDate))
        let newA = ThreadNode(message: makeMessage(id: "a-new", date: newerDate))
        let newB = ThreadNode(message: makeMessage(id: "z-new", date: newerDate))
        let nodes = [oldA, oldB, newA, newB]

        XCTAssertEqual(ThreadCanvasViewModel.boundaryNodeID(in: nodes, boundary: .oldest), "a-old")
        XCTAssertEqual(ThreadCanvasViewModel.boundaryNodeID(in: nodes, boundary: .newest), "z-new")
    }

    func test_resolveRenderableJumpTargetID_returnsPreferredWhenPresent() {
        let calendar = Calendar(identifier: .gregorian)
        let baseDate = calendar.date(from: DateComponents(year: 2025, month: 3, day: 8, hour: 12))!
        let olderDate = calendar.date(byAdding: .day, value: -1, to: baseDate)!

        let preferred = ThreadNode(message: makeMessage(id: "preferred", date: baseDate))
        let other = ThreadNode(message: makeMessage(id: "other", date: olderDate))
        let nodes = [other, preferred]

        let target = ThreadCanvasViewModel.resolveRenderableJumpTargetID(preferredNodeID: "preferred",
                                                                          renderableCandidates: nodes,
                                                                          boundary: .oldest,
                                                                          allowFallback: false)

        XCTAssertEqual(target, "preferred")
    }

    func test_resolveRenderableJumpTargetID_withoutFallbackReturnsNilWhenPreferredMissing() {
        let calendar = Calendar(identifier: .gregorian)
        let baseDate = calendar.date(from: DateComponents(year: 2025, month: 3, day: 8, hour: 12))!

        let older = ThreadNode(message: makeMessage(id: "older", date: calendar.date(byAdding: .day, value: -2, to: baseDate)!))
        let newer = ThreadNode(message: makeMessage(id: "newer", date: calendar.date(byAdding: .day, value: -1, to: baseDate)!))
        let nodes = [older, newer]

        let target = ThreadCanvasViewModel.resolveRenderableJumpTargetID(preferredNodeID: "missing",
                                                                          renderableCandidates: nodes,
                                                                          boundary: .newest,
                                                                          allowFallback: false)

        XCTAssertNil(target)
    }

    func test_resolveRenderableJumpTargetID_withFallbackReturnsBoundaryWhenPreferredMissing() {
        let calendar = Calendar(identifier: .gregorian)
        let baseDate = calendar.date(from: DateComponents(year: 2025, month: 3, day: 8, hour: 12))!

        let older = ThreadNode(message: makeMessage(id: "older", date: calendar.date(byAdding: .day, value: -2, to: baseDate)!))
        let newer = ThreadNode(message: makeMessage(id: "newer", date: calendar.date(byAdding: .day, value: -1, to: baseDate)!))
        let nodes = [older, newer]

        let oldestFallback = ThreadCanvasViewModel.resolveRenderableJumpTargetID(preferredNodeID: "missing",
                                                                                  renderableCandidates: nodes,
                                                                                  boundary: .oldest)
        let newestFallback = ThreadCanvasViewModel.resolveRenderableJumpTargetID(preferredNodeID: "missing",
                                                                                  renderableCandidates: nodes,
                                                                                  boundary: .newest)

        XCTAssertEqual(oldestFallback, "older")
        XCTAssertEqual(newestFallback, "newer")
    }

    func test_resolvedPreservedJumpX_keepsExistingX() {
        let preserved = ThreadCanvasViewModel.resolvedPreservedJumpX(existingPreservedX: 320, currentX: 96)
        XCTAssertEqual(preserved, 320)
    }

    func test_resolveVerticalJump_oldestUsesTopAlignedTarget() {
        let resolution = ThreadCanvasViewModel.resolveVerticalJump(boundary: .oldest,
                                                                   targetMinYInScrollContent: 420,
                                                                   targetMidYInScrollContent: 480,
                                                                   totalTopPadding: 120,
                                                                   viewportHeight: 600,
                                                                   documentHeight: 2_000,
                                                                   clipHeight: 600)

        XCTAssertEqual(resolution.desiredY, 390)
        XCTAssertEqual(resolution.clampedY, 390)
        XCTAssertFalse(resolution.didClampToBottom)
    }

    func test_resolveVerticalJump_newestCentersTargetAndClampsToBottom() {
        let resolution = ThreadCanvasViewModel.resolveVerticalJump(boundary: .newest,
                                                                   targetMinYInScrollContent: 900,
                                                                   targetMidYInScrollContent: 980,
                                                                   totalTopPadding: 100,
                                                                   viewportHeight: 600,
                                                                   documentHeight: 1_200,
                                                                   clipHeight: 600)

        XCTAssertEqual(resolution.desiredY, 680)
        XCTAssertEqual(resolution.maxY, 600)
        XCTAssertEqual(resolution.clampedY, 600)
        XCTAssertTrue(resolution.didClampToBottom)
    }

    func test_shouldConsumeVerticalJump_falseWhenNotAtTargetAndNotBottomClamped() {
        let shouldConsume = ThreadCanvasViewModel.shouldConsumeVerticalJump(finalY: 500,
                                                                            targetY: 560,
                                                                            didClampToBottom: false)
        XCTAssertFalse(shouldConsume)
    }

    func test_shouldConsumeVerticalJump_trueWhenBottomClampIsFinal() {
        let shouldConsume = ThreadCanvasViewModel.shouldConsumeVerticalJump(finalY: 520,
                                                                            targetY: 600,
                                                                            didClampToBottom: true)
        XCTAssertTrue(shouldConsume)
    }

    private func makeMessage(id: String, date: Date) -> EmailMessage {
        EmailMessage(messageID: id,
                     mailboxID: "inbox",
                     accountName: "",
                     subject: id,
                     from: "sender@example.com",
                     to: "me@example.com",
                     date: date,
                     snippet: "",
                     isUnread: false,
                     inReplyTo: nil,
                     references: [],
                     threadID: "thread-\(id)")
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

    func testPinnedFolderThreadsAppearBeforeUnpinnedThreads() {
        let calendar = Calendar(identifier: .gregorian)
        let today = calendar.date(from: DateComponents(year: 2025, month: 3, day: 8, hour: 12))!

        let pinnedThread = EmailMessage(messageID: "pinned",
                                        mailboxID: "inbox",
                                        accountName: "",
                                        subject: "Pinned",
                                        from: "a@example.com",
                                        to: "me@example.com",
                                        date: calendar.date(byAdding: .day, value: -3, to: today)!,
                                        snippet: "",
                                        isUnread: false,
                                        inReplyTo: nil,
                                        references: [],
                                        threadID: "thread-pinned")
        let unpinnedThread = EmailMessage(messageID: "unpinned",
                                          mailboxID: "inbox",
                                          accountName: "",
                                          subject: "Unpinned",
                                          from: "b@example.com",
                                          to: "me@example.com",
                                          date: calendar.date(byAdding: .day, value: -1, to: today)!,
                                          snippet: "",
                                          isUnread: false,
                                          inReplyTo: nil,
                                          references: [],
                                          threadID: "thread-unpinned")

        let roots = [
            ThreadNode(message: pinnedThread),
            ThreadNode(message: unpinnedThread)
        ]

        let folder = ThreadFolder(id: "folder-pinned",
                                  title: "Pinned Folder",
                                  color: ThreadFolderColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1),
                                  threadIDs: ["thread-pinned"],
                                  parentID: nil)
        let membership = ThreadCanvasViewModel.folderMembershipMap(for: [folder])

        let metrics = ThreadCanvasLayoutMetrics(zoom: 1.0)
        let layout = ThreadCanvasViewModel.canvasLayout(for: roots,
                                                        metrics: metrics,
                                                        today: today,
                                                        calendar: calendar,
                                                        folders: [folder],
                                                        pinnedFolderIDs: Set(["folder-pinned"]),
                                                        folderMembershipByThreadID: membership)

        XCTAssertEqual(layout.columns.first?.id, "thread-pinned")
        XCTAssertEqual(layout.columns.dropFirst().first?.id, "thread-unpinned")
    }

    func testPinnedFoldersRemainSortedByLatestDate() {
        let calendar = Calendar(identifier: .gregorian)
        let today = calendar.date(from: DateComponents(year: 2025, month: 3, day: 8, hour: 12))!

        let olderPinned = EmailMessage(messageID: "older-pinned",
                                       mailboxID: "inbox",
                                       accountName: "",
                                       subject: "Older",
                                       from: "a@example.com",
                                       to: "me@example.com",
                                       date: calendar.date(byAdding: .day, value: -3, to: today)!,
                                       snippet: "",
                                       isUnread: false,
                                       inReplyTo: nil,
                                       references: [],
                                       threadID: "thread-older")
        let newerPinned = EmailMessage(messageID: "newer-pinned",
                                       mailboxID: "inbox",
                                       accountName: "",
                                       subject: "Newer",
                                       from: "b@example.com",
                                       to: "me@example.com",
                                       date: calendar.date(byAdding: .day, value: -1, to: today)!,
                                       snippet: "",
                                       isUnread: false,
                                       inReplyTo: nil,
                                       references: [],
                                       threadID: "thread-newer")

        let roots = [
            ThreadNode(message: olderPinned),
            ThreadNode(message: newerPinned)
        ]

        let olderFolder = ThreadFolder(id: "folder-older",
                                       title: "Older Folder",
                                       color: ThreadFolderColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1),
                                       threadIDs: ["thread-older"],
                                       parentID: nil)
        let newerFolder = ThreadFolder(id: "folder-newer",
                                       title: "Newer Folder",
                                       color: ThreadFolderColor(red: 0.3, green: 0.5, blue: 0.7, alpha: 1),
                                       threadIDs: ["thread-newer"],
                                       parentID: nil)
        let membership = ThreadCanvasViewModel.folderMembershipMap(for: [olderFolder, newerFolder])

        let metrics = ThreadCanvasLayoutMetrics(zoom: 1.0)
        let layout = ThreadCanvasViewModel.canvasLayout(for: roots,
                                                        metrics: metrics,
                                                        today: today,
                                                        calendar: calendar,
                                                        folders: [olderFolder, newerFolder],
                                                        pinnedFolderIDs: Set(["folder-older", "folder-newer"]),
                                                        folderMembershipByThreadID: membership)

        XCTAssertEqual(layout.columns.first?.id, "thread-newer")
        XCTAssertEqual(layout.columns.dropFirst().first?.id, "thread-older")
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

    func testTimelineLayoutUsesDynamicHeightsForLongSummaries() {
        let calendar = Calendar(identifier: .gregorian)
        let today = calendar.date(from: DateComponents(year: 2025, month: 4, day: 12, hour: 11))!
        let longText = String(repeating: "Long summary ", count: 24)

        let longMessage = EmailMessage(messageID: "long",
                                       mailboxID: "inbox",
                                       accountName: "",
                                       subject: "Long",
                                       from: "long@example.com",
                                       to: "me@example.com",
                                       date: today,
                                       snippet: "",
                                       isUnread: false,
                                       inReplyTo: nil,
                                       references: [],
                                       threadID: "thread-long")
        let shortMessage = EmailMessage(messageID: "short",
                                        mailboxID: "inbox",
                                        accountName: "",
                                        subject: "Short",
                                        from: "short@example.com",
                                        to: "me@example.com",
                                        date: calendar.date(byAdding: .minute, value: -30, to: today)!,
                                        snippet: "",
                                        isUnread: false,
                                        inReplyTo: nil,
                                        references: [],
                                        threadID: "thread-long")

        let root = ThreadNode(message: longMessage, children: [ThreadNode(message: shortMessage)])
        let summaries: [String: ThreadSummaryState] = [
            longMessage.messageID: ThreadSummaryState(text: longText, statusMessage: "", isSummarizing: false),
            shortMessage.messageID: ThreadSummaryState(text: "Short summary.", statusMessage: "", isSummarizing: false)
        ]

        let metrics = ThreadCanvasLayoutMetrics(zoom: 1.0)
        let layout = ThreadCanvasViewModel.canvasLayout(for: [root],
                                                        metrics: metrics,
                                                        viewMode: .timeline,
                                                        today: today,
                                                        calendar: calendar,
                                                        nodeSummaries: summaries,
                                                        timelineTagsByNodeID: [
                                                            longMessage.messageID: ["AI", "Follow-up", "Billing"],
                                                            shortMessage.messageID: ["Quick"]
                                                        ])

        guard let columnNodes = layout.columns.first?.nodes, columnNodes.count == 2 else {
            XCTFail("Expected two timeline nodes")
            return
        }

        let firstNode = columnNodes[0]
        let secondNode = columnNodes[1]

        XCTAssertGreaterThan(firstNode.frame.height, secondNode.frame.height)
        XCTAssertEqual(secondNode.frame.minY,
                       firstNode.frame.maxY + metrics.nodeVerticalSpacing,
                       accuracy: 0.5)
        XCTAssertGreaterThan(layout.days.first?.height ?? 0, metrics.dayHeight)
    }

    func testPinnedFoldersSortedBeforeUnpinned() {
        let folders = [
            ThreadFolder(id: "a", title: "A", color: ThreadFolderColor(red: 0, green: 0, blue: 0, alpha: 1), threadIDs: [], parentID: nil),
            ThreadFolder(id: "b", title: "B", color: ThreadFolderColor(red: 0, green: 0, blue: 0, alpha: 1), threadIDs: [], parentID: nil),
            ThreadFolder(id: "c", title: "C", color: ThreadFolderColor(red: 0, green: 0, blue: 0, alpha: 1), threadIDs: [], parentID: nil),
            ThreadFolder(id: "d", title: "D", color: ThreadFolderColor(red: 0, green: 0, blue: 0, alpha: 1), threadIDs: [], parentID: nil)
        ]

        let result = ThreadCanvasViewModel.pinnedFirstFolders(folders,
                                                              pinnedIDs: Set(["c", "a"]))

        XCTAssertEqual(result.map(\.id), ["a", "c", "b", "d"])
    }

    func testLayoutPopulatedDayIndicesMatchNodes() {
        let calendar = Calendar(identifier: .gregorian)
        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = TimeZone(secondsFromGMT: 0)
        components.year = 2025
        components.month = 3
        components.day = 8
        components.hour = 12
        let today = calendar.date(from: components)!

        let dayZero = EmailMessage(messageID: "day0",
                                   mailboxID: "inbox",
                                   accountName: "",
                                   subject: "Today",
                                   from: "a@example.com",
                                   to: "me@example.com",
                                   date: today,
                                   snippet: "",
                                   isUnread: false,
                                   inReplyTo: nil,
                                   references: [],
                                   threadID: "thread-0")
        let dayTwo = EmailMessage(messageID: "day2",
                                  mailboxID: "inbox",
                                  accountName: "",
                                  subject: "Two Days Ago",
                                  from: "b@example.com",
                                  to: "me@example.com",
                                  date: calendar.date(byAdding: .day, value: -2, to: today)!,
                                  snippet: "",
                                  isUnread: false,
                                  inReplyTo: nil,
                                  references: [],
                                  threadID: "thread-2")

        let rootA = ThreadNode(message: dayZero)
        let rootB = ThreadNode(message: dayTwo)
        let metrics = ThreadCanvasLayoutMetrics(zoom: 1.0, dayCount: 3)
        let layout = ThreadCanvasViewModel.canvasLayout(for: [rootA, rootB],
                                                        metrics: metrics,
                                                        today: today,
                                                        calendar: calendar)

        XCTAssertEqual(layout.populatedDayIndices, Set([0, 2]))
    }

    func testEmptyDayIntervalsUseCachedPopulatedDays() {
        let calendar = Calendar(identifier: .gregorian)
        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = TimeZone(secondsFromGMT: 0)
        components.year = 2025
        components.month = 3
        components.day = 8
        components.hour = 12
        let today = calendar.date(from: components)!

        let dayZero = EmailMessage(messageID: "only-day0",
                                   mailboxID: "inbox",
                                   accountName: "",
                                   subject: "Today",
                                   from: "a@example.com",
                                   to: "me@example.com",
                                   date: today,
                                   snippet: "",
                                   isUnread: false,
                                   inReplyTo: nil,
                                   references: [],
                                   threadID: "thread-0")
        let root = ThreadNode(message: dayZero)
        let metrics = ThreadCanvasLayoutMetrics(zoom: 1.0, dayCount: 3)
        let layout = ThreadCanvasViewModel.canvasLayout(for: [root],
                                                        metrics: metrics,
                                                        today: today,
                                                        calendar: calendar)

        let intervals = ThreadCanvasViewModel.emptyDayIntervals(for: layout,
                                                                visibleRange: 0...2,
                                                                today: today,
                                                                calendar: calendar)

        XCTAssertEqual(intervals.count, 1)
        let expectedStart = ThreadCanvasDateHelper.dayDate(for: 2, today: today, calendar: calendar)
        let expectedEnd = calendar.date(byAdding: .day,
                                        value: 1,
                                        to: ThreadCanvasDateHelper.dayDate(for: 1, today: today, calendar: calendar))!
        XCTAssertEqual(intervals[0].start, expectedStart)
        XCTAssertEqual(intervals[0].end, expectedEnd)
    }

    func test_makeFolderMinimapModel_usesProvidedThreadScopeIDs() {
        let calendar = Calendar(identifier: .gregorian)
        let base = calendar.date(from: DateComponents(year: 2025, month: 3, day: 8, hour: 12))!
        let oldNode = ThreadNode(message: makeMessage(id: "a", date: calendar.date(byAdding: .day, value: -1, to: base)!))
        let newNode = ThreadNode(message: makeMessage(id: "b", date: base))
        let sourceNodes = [
            FolderMinimapSourceNode(threadID: "manual-group", node: oldNode),
            FolderMinimapSourceNode(threadID: "manual-group", node: newNode)
        ]

        let model = ThreadCanvasViewModel.makeFolderMinimapModel(folderID: "folder-1", sourceNodes: sourceNodes)

        XCTAssertEqual(model?.folderID, "folder-1")
        XCTAssertEqual(Set(model?.nodes.map(\.threadID) ?? []), Set(["manual-group"]))
        XCTAssertEqual(model?.edges.count, 1)
    }

    func test_resolveFolderMinimapTargetNodeID_coordinateMapping_prefersNearestInColumn() {
        let now = Date(timeIntervalSinceReferenceDate: 10_000)
        let model = FolderMinimapModel(
            folderID: "folder-1",
            nodes: [
                FolderMinimapNode(id: "old-left", threadID: "left", normalizedX: 0.0, normalizedY: 0.9),
                FolderMinimapNode(id: "new-left", threadID: "left", normalizedX: 0.0, normalizedY: 0.1),
                FolderMinimapNode(id: "right", threadID: "right", normalizedX: 1.0, normalizedY: 0.5)
            ],
            edges: [],
            newestDate: now,
            oldestDate: now.addingTimeInterval(-3_600),
            timeTicks: []
        )

        let target = ThreadCanvasViewModel.resolveFolderMinimapTargetNodeID(model: model,
                                                                            normalizedPoint: CGPoint(x: 0.05, y: 0.12))

        XCTAssertEqual(target, "new-left")
    }

    func test_resolveFolderMinimapTargetNodeID_unstableMapping_fallsBackToNearestNode() {
        let now = Date(timeIntervalSinceReferenceDate: 10_000)
        let model = FolderMinimapModel(
            folderID: "folder-1",
            nodes: [
                FolderMinimapNode(id: "left", threadID: "left", normalizedX: 0.0, normalizedY: 0.2),
                FolderMinimapNode(id: "right", threadID: "right", normalizedX: 1.0, normalizedY: 0.8)
            ],
            edges: [],
            newestDate: now,
            oldestDate: now.addingTimeInterval(-3_600),
            timeTicks: []
        )

        let target = ThreadCanvasViewModel.resolveFolderMinimapTargetNodeID(model: model,
                                                                            normalizedPoint: CGPoint(x: 0.45, y: 0.78),
                                                                            mappingTolerance: 0.1)

        XCTAssertEqual(target, "right")
    }

    func test_selectFolder_preservesNodeSelection() {
        let viewModel = ThreadCanvasViewModel(settings: AutoRefreshSettings(),
                                              inspectorSettings: InspectorViewSettings(),
                                              pinnedFolderSettings: PinnedFolderSettings())
        viewModel.selectNode(id: "node-1")
        viewModel.selectFolder(id: "folder-1")

        XCTAssertEqual(viewModel.selectedNodeID, "node-1")
        XCTAssertEqual(viewModel.selectedNodeIDs, Set(["node-1"]))
    }

    func test_resolveFolderMinimapSelectedNodeID_returnsOnlyInScope() {
        let now = Date(timeIntervalSinceReferenceDate: 10_000)
        let model = FolderMinimapModel(
            folderID: "folder-1",
            nodes: [
                FolderMinimapNode(id: "in-scope", threadID: "left", normalizedX: 0.0, normalizedY: 0.2)
            ],
            edges: [],
            newestDate: now,
            oldestDate: now.addingTimeInterval(-1_800),
            timeTicks: []
        )

        XCTAssertEqual(ThreadCanvasViewModel.resolveFolderMinimapSelectedNodeID(selectedNodeID: "in-scope",
                                                                                 model: model),
                       "in-scope")
        XCTAssertNil(ThreadCanvasViewModel.resolveFolderMinimapSelectedNodeID(selectedNodeID: "outside",
                                                                               model: model))
    }

    func test_projectFolderMinimapViewport_clampsToOverlayBounds() {
        let overlay = CGRect(x: 100, y: 200, width: 120, height: 80)
        let viewport = CGRect(x: 60, y: 220, width: 100, height: 50)

        let projected = ThreadCanvasViewModel.projectFolderMinimapViewport(overlayFrame: overlay,
                                                                            viewportRect: viewport)

        XCTAssertEqual(projected?.minX, 0, accuracy: 0.0001)
        XCTAssertEqual(projected?.minY, 0.25, accuracy: 0.0001)
        XCTAssertEqual(projected?.width, 0.5, accuracy: 0.0001)
        XCTAssertEqual(projected?.height, 0.625, accuracy: 0.0001)
    }

    func test_makeFolderMinimapTimeTicks_ordersNewestToOldest() {
        let newest = Date(timeIntervalSinceReferenceDate: 10_000)
        let oldest = newest.addingTimeInterval(-4_000)

        let ticks = ThreadCanvasViewModel.makeFolderMinimapTimeTicks(newestDate: newest,
                                                                      oldestDate: oldest,
                                                                      tickCount: 5)

        XCTAssertEqual(ticks.count, 5)
        XCTAssertEqual(ticks.first?.normalizedY, 0, accuracy: 0.0001)
        XCTAssertEqual(ticks.last?.normalizedY, 1, accuracy: 0.0001)
        XCTAssertEqual(ticks.first?.date, newest)
        XCTAssertEqual(ticks.last?.date, oldest)
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
        let pinnedFolderSettings = PinnedFolderSettings()
        let viewModel = ThreadCanvasViewModel(settings: settings,
                                              inspectorSettings: inspectorSettings,
                                              pinnedFolderSettings: pinnedFolderSettings,
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
