import CoreData
import XCTest
@testable import BetterMail

final class ThreadSummaryCacheTests: XCTestCase {
    func test_BuildThreads_RepeatedEarlierInReplyTo_DoesNotDropCyclicComponent() throws {
        let root = EmailMessage(messageID: "root@example.com",
                                mailboxID: "Inbox",
                                accountName: "Example",
                                subject: "Opening context",
                                from: "a@example.com",
                                to: "b@example.com",
                                date: Date(timeIntervalSince1970: 100),
                                snippet: "Opening context",
                                isUnread: false,
                                inReplyTo: nil,
                                references: [])
        let bridge = EmailMessage(messageID: "bridge@example.com",
                                  mailboxID: "Inbox",
                                  accountName: "Example",
                                  subject: "First reply",
                                  from: "b@example.com",
                                  to: "a@example.com",
                                  date: Date(timeIntervalSince1970: 200),
                                  snippet: "First reply",
                                  isUnread: false,
                                  inReplyTo: root.messageID,
                                  references: [root.messageID])
        let malformedReply = EmailMessage(messageID: "reply@example.com",
                                          mailboxID: "Inbox",
                                          accountName: "Example",
                                          subject: "Follow-up",
                                          from: "a@example.com",
                                          to: "b@example.com",
                                          date: Date(timeIntervalSince1970: 300),
                                          snippet: "Follow-up",
                                          isUnread: false,
                                          inReplyTo: root.messageID,
                                          references: [root.messageID, bridge.messageID])

        let result = JWZThreader().buildThreads(from: [root, bridge, malformedReply])
        let threadedRoot = try XCTUnwrap(result.roots.first)
        func flattenMessageIDs(_ node: ThreadNode) -> [String] {
            [node.message.messageID] + node.children.flatMap(flattenMessageIDs)
        }

        XCTAssertEqual(result.roots.count, 1)
        XCTAssertEqual(result.threads.first?.messageCount, 3)
        XCTAssertEqual(Set(flattenMessageIDs(threadedRoot)),
                       Set([root.messageID, bridge.messageID, malformedReply.messageID]))
    }

    func testScopedSummaryCachePersistsAndFetches() async throws {
        let defaults = UserDefaults(suiteName: "ThreadSummaryCacheTests-\(UUID().uuidString)")!
        let store = MessageStore(userDefaults: defaults, storeType: NSInMemoryStoreType)
        let nodeEntry = SummaryCacheEntry(scope: .emailNode,
                                          scopeID: "node-1",
                                          summaryText: "Cached node summary",
                                          generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
                                          fingerprint: "fingerprint-a",
                                          provider: "foundation-models")
        let folderEntry = SummaryCacheEntry(scope: .folder,
                                            scopeID: "folder-1",
                                            summaryText: "Cached folder summary",
                                            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
                                            fingerprint: "fingerprint-b",
                                            provider: "foundation-models")

        try await store.upsertSummaries([nodeEntry, folderEntry])
        let fetchedNodes = try await store.fetchSummaries(scope: .emailNode, ids: [nodeEntry.scopeID])
        let fetchedFolders = try await store.fetchSummaries(scope: .folder, ids: [folderEntry.scopeID])

        XCTAssertEqual(fetchedNodes.count, 1)
        XCTAssertEqual(fetchedNodes.first?.summaryText, nodeEntry.summaryText)
        XCTAssertEqual(fetchedFolders.count, 1)
        XCTAssertEqual(fetchedFolders.first?.summaryText, folderEntry.summaryText)

        try await store.deleteSummaries(scope: .emailNode, ids: [nodeEntry.scopeID])
        let afterDelete = try await store.fetchSummaries(scope: .emailNode, ids: [nodeEntry.scopeID])
        XCTAssertTrue(afterDelete.isEmpty)
    }

    func testScopedSummaryCacheDeduplicatesByNewestGeneratedAt() async throws {
        let defaults = UserDefaults(suiteName: "ThreadSummaryCacheTests-\(UUID().uuidString)")!
        let store = MessageStore(userDefaults: defaults, storeType: NSInMemoryStoreType)
        let olderEntry = SummaryCacheEntry(scope: .emailNode,
                                           scopeID: "node-1",
                                           summaryText: "Older summary",
                                           generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
                                           fingerprint: "fingerprint-old",
                                           provider: "foundation-models")
        let newerEntry = SummaryCacheEntry(scope: .emailNode,
                                           scopeID: "node-1",
                                           summaryText: "Newer summary",
                                           generatedAt: Date(timeIntervalSince1970: 1_700_000_100),
                                           fingerprint: "fingerprint-new",
                                           provider: "foundation-models")

        try await store.upsertSummaries([olderEntry, newerEntry])
        let fetchedNodes = try await store.fetchSummaries(scope: .emailNode, ids: [olderEntry.scopeID])

        XCTAssertEqual(fetchedNodes.count, 1)
        XCTAssertEqual(fetchedNodes.first?.summaryText, newerEntry.summaryText)
        XCTAssertEqual(fetchedNodes.first?.fingerprint, newerEntry.fingerprint)
    }

    func testScopedSummaryCacheRejectsSupersededOlderWrite() async throws {
        let defaults = UserDefaults(suiteName: "ThreadSummaryCacheTests-\(UUID().uuidString)")!
        let store = MessageStore(userDefaults: defaults, storeType: NSInMemoryStoreType)
        let newerEntry = SummaryCacheEntry(scope: .graphTitle,
                                           scopeID: "node-1",
                                           summaryText: "2/2 · New role",
                                           generatedAt: Date(timeIntervalSince1970: 1_700_000_100),
                                           fingerprint: "new-fingerprint",
                                           provider: "foundation-models")
        let supersededEntry = SummaryCacheEntry(scope: .graphTitle,
                                                scopeID: "node-1",
                                                summaryText: "1/1 · Old role",
                                                generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
                                                fingerprint: "old-fingerprint",
                                                provider: "foundation-models")

        try await store.upsertSummaries([newerEntry])
        try await store.upsertSummaries([supersededEntry])

        let fetched = try await store.fetchSummaries(scope: .graphTitle, ids: [newerEntry.scopeID])
        XCTAssertEqual(fetched.first?.summaryText, newerEntry.summaryText)
        XCTAssertEqual(fetched.first?.fingerprint, newerEntry.fingerprint)
    }

    func testScopedSummaryCacheSerializesOverlappingNewestWinsWrites() async throws {
        let defaults = UserDefaults(suiteName: "ThreadSummaryCacheTests-\(UUID().uuidString)")!
        let store = MessageStore(userDefaults: defaults, storeType: NSInMemoryStoreType)
        let ids = (0..<40).map { "node-\($0)" }
        let olderEntries = ids.map {
            SummaryCacheEntry(scope: .graphTitle,
                              scopeID: $0,
                              summaryText: "Old role",
                              generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
                              fingerprint: "old-fingerprint",
                              provider: "foundation-models")
        }
        let newerEntries = ids.map {
            SummaryCacheEntry(scope: .graphTitle,
                              scopeID: $0,
                              summaryText: "New role",
                              generatedAt: Date(timeIntervalSince1970: 1_700_000_100),
                              fingerprint: "new-fingerprint",
                              provider: "foundation-models")
        }

        async let olderWrite: Void = store.upsertSummaries(olderEntries)
        async let newerWrite: Void = store.upsertSummaries(newerEntries)
        _ = try await (olderWrite, newerWrite)

        let fetched = try await store.fetchSummaries(scope: .graphTitle, ids: ids)
        XCTAssertEqual(fetched.count, ids.count)
        XCTAssertTrue(fetched.allSatisfy { $0.summaryText == "New role" })
        XCTAssertTrue(fetched.allSatisfy { $0.fingerprint == "new-fingerprint" })
    }

    func testNodeSummaryFingerprintChangesWhenInputsChange() {
        let previous = EmailSummaryContextEntry(messageID: "a",
                                                subject: "Invoice",
                                                bodySnippet: "Draft",
                                                direction: .previous,
                                                relationship: .automaticReply)
        let context = EmailSummaryThreadContext(position: 2,
                                                totalMessages: 2,
                                                previousMessage: previous,
                                                nextMessage: nil)
        let base = ThreadSummaryFingerprint.makeNode(subject: "Invoice",
                                                     body: "Paid on Friday",
                                                     threadRevision: "revision-a",
                                                     context: context,
                                                     providerID: "test")
        let changedBody = ThreadSummaryFingerprint.makeNode(subject: "Invoice",
                                                            body: "Paid on Monday",
                                                            threadRevision: "revision-a",
                                                            context: context,
                                                            providerID: "test")
        let changedContext = EmailSummaryThreadContext(
            position: 2,
            totalMessages: 2,
            previousMessage: EmailSummaryContextEntry(messageID: "b",
                                                       subject: "Invoice",
                                                       bodySnippet: "Updated",
                                                       direction: .previous,
                                                       relationship: .manualThreadLink),
            nextMessage: nil
        )
        let changedPrior = ThreadSummaryFingerprint.makeNode(subject: "Invoice",
                                                             body: "Paid on Friday",
                                                             threadRevision: "revision-b",
                                                             context: changedContext,
                                                             providerID: "test")
        XCTAssertNotEqual(base, changedBody)
        XCTAssertNotEqual(base, changedPrior)
    }

    func testFolderFingerprintChangesWhenEntriesChange() {
        let base = ThreadSummaryFingerprint.makeFolder(nodeEntries: [FolderSummaryFingerprintEntry(nodeID: "a",
                                                                                                   nodeFingerprint: "one")])
        let changed = ThreadSummaryFingerprint.makeFolder(nodeEntries: [FolderSummaryFingerprintEntry(nodeID: "a",
                                                                                                      nodeFingerprint: "two")])
        XCTAssertNotEqual(base, changed)
        XCTAssertNotEqual(base,
                          ThreadSummaryFingerprint.makeFolder(title: "Renamed",
                                                              nodeEntries: [FolderSummaryFingerprintEntry(nodeID: "a",
                                                                                                          nodeFingerprint: "one")]))
    }

    @MainActor
    func testNodeSummaryUsesImmediateThreadContext() async throws {
        let defaults = UserDefaults(suiteName: "ThreadSummaryCacheTests-\(UUID().uuidString)")!
        let store = MessageStore(userDefaults: defaults, storeType: NSInMemoryStoreType)
        let provider = TestSummaryProvider(emailResult: "Generated")
        let capability = EmailSummaryCapability(provider: provider,
                                                statusMessage: "Ready",
                                                providerID: "test")
        let settings = AutoRefreshSettings()
        let inspectorSettings = InspectorViewSettings()
        let pinnedFolderSettings = PinnedFolderSettings()
        let viewModel = ThreadCanvasViewModel(settings: settings,
                                              inspectorSettings: inspectorSettings,
                                              pinnedFolderSettings: pinnedFolderSettings,
                                              store: store,
                                              summaryCapability: capability,
                                              folderSummaryDebounceInterval: 0)

        let calendar = Calendar(identifier: .gregorian)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let messageB = EmailMessage(messageID: "<b>",
                                    mailboxID: "inbox",
                                    accountName: "",
                                    subject: "Older",
                                    from: "b@example.com",
                                    to: "me@example.com",
                                    date: calendar.date(byAdding: .day, value: -1, to: now)!,
                                    snippet: "Body B",
                                    isUnread: false,
                                    inReplyTo: nil,
                                    references: [])
        let messageA = EmailMessage(messageID: "<a>",
                                    mailboxID: "inbox",
                                    accountName: "",
                                    subject: "Latest",
                                    from: "a@example.com",
                                    to: "me@example.com",
                                    date: now,
                                    snippet: "Body A",
                                    isUnread: false,
                                    inReplyTo: messageB.messageID,
                                    references: [messageB.messageID])
        let threader = JWZThreader()
        let result = threader.buildThreads(from: [messageA, messageB])
        guard let root = result.roots.first else {
            XCTFail("Expected a thread root")
            return
        }

        viewModel.applyRethreadResultForTesting(roots: [root])
        try await waitForNodeSummaryRefresh(viewModel)

        let latestRequest = provider.emailRequests.first { $0.subject == "Latest" }
        XCTAssertNotNil(latestRequest)
        XCTAssertEqual(latestRequest?.threadContext.position, 2)
        XCTAssertEqual(latestRequest?.threadContext.totalMessages, 2)
        XCTAssertEqual(latestRequest?.threadContext.previousMessage?.subject, "Older")
        XCTAssertEqual(latestRequest?.threadContext.previousMessage?.relationship, .automaticReply)
        XCTAssertNil(latestRequest?.threadContext.nextMessage)

        let state = viewModel.summaryState(for: root.id)
        XCTAssertNotNil(state)
    }

    func testContextBuilderProvidesOnlyImmediateNaturalNeighbours() {
        let sources = [
            makeSource(id: "a", date: 10, automaticThreadID: "reply-thread"),
            makeSource(id: "b", date: 20, automaticThreadID: "reply-thread"),
            makeSource(id: "c", date: 30, automaticThreadID: "reply-thread")
        ]

        let build = ThreadSummaryContextBuilder.build(sources: sources, providerID: "test")
        let middle = build.inputsByNodeID["b"]?.request.threadContext

        XCTAssertEqual(middle?.position, 2)
        XCTAssertEqual(middle?.totalMessages, 3)
        XCTAssertEqual(middle?.previousMessage?.messageID, "a")
        XCTAssertEqual(middle?.nextMessage?.messageID, "c")
        XCTAssertEqual(middle?.previousMessage?.relationship, .automaticReply)
        XCTAssertEqual(middle?.nextMessage?.relationship, .automaticReply)
    }

    func testContextBuilderMarksOnlyManualBoundaries() {
        let sources = [
            makeSource(id: "a", date: 10, automaticThreadID: "reply-a"),
            makeSource(id: "b", date: 20, automaticThreadID: "reply-a"),
            makeSource(id: "c", date: 30, automaticThreadID: "reply-b", isManualAttachment: true)
        ]

        let build = ThreadSummaryContextBuilder.build(sources: sources, providerID: "test")

        XCTAssertEqual(build.inputsByNodeID["b"]?.request.threadContext.previousMessage?.relationship,
                       .automaticReply)
        XCTAssertEqual(build.inputsByNodeID["b"]?.request.threadContext.nextMessage?.relationship,
                       .manualThreadLink)
        XCTAssertEqual(build.inputsByNodeID["c"]?.request.threadContext.previousMessage?.relationship,
                       .manualThreadLink)
    }

    func testThreadMembershipChangeInvalidatesEveryExistingNodeFingerprint() {
        let initial = ThreadSummaryContextBuilder.build(
            sources: [
                makeSource(id: "a", date: 10, automaticThreadID: "reply-thread"),
                makeSource(id: "b", date: 20, automaticThreadID: "reply-thread")
            ],
            providerID: "test"
        )
        let expanded = ThreadSummaryContextBuilder.build(
            sources: [
                makeSource(id: "a", date: 10, automaticThreadID: "reply-thread"),
                makeSource(id: "b", date: 20, automaticThreadID: "reply-thread"),
                makeSource(id: "c", date: 30, automaticThreadID: "reply-thread")
            ],
            providerID: "test"
        )

        XCTAssertNotEqual(initial.inputsByNodeID["a"]?.fingerprint,
                          expanded.inputsByNodeID["a"]?.fingerprint)
        XCTAssertNotEqual(initial.inputsByNodeID["b"]?.fingerprint,
                          expanded.inputsByNodeID["b"]?.fingerprint)
    }

    func testSeparateThreadsInOneGroupDoNotBecomeSummaryNeighbours() {
        let build = ThreadSummaryContextBuilder.build(
            sources: [
                makeSource(id: "a", effectiveThreadID: "thread-a", date: 10, automaticThreadID: "reply-a"),
                makeSource(id: "b", effectiveThreadID: "thread-b", date: 20, automaticThreadID: "reply-b")
            ],
            providerID: "test"
        )

        XCTAssertNil(build.inputsByNodeID["a"]?.request.threadContext.previousMessage)
        XCTAssertNil(build.inputsByNodeID["a"]?.request.threadContext.nextMessage)
        XCTAssertNil(build.inputsByNodeID["b"]?.request.threadContext.previousMessage)
        XCTAssertNil(build.inputsByNodeID["b"]?.request.threadContext.nextMessage)
    }

    func testThreadSplitRebuildsBothResultingContexts() {
        let merged = ThreadSummaryContextBuilder.build(
            sources: [
                makeSource(id: "a", effectiveThreadID: "manual", date: 10, automaticThreadID: "reply-a"),
                makeSource(id: "b", effectiveThreadID: "manual", date: 20, automaticThreadID: "reply-b")
            ],
            providerID: "test"
        )
        let split = ThreadSummaryContextBuilder.build(
            sources: [
                makeSource(id: "a", effectiveThreadID: "reply-a", date: 10, automaticThreadID: "reply-a"),
                makeSource(id: "b", effectiveThreadID: "reply-b", date: 20, automaticThreadID: "reply-b")
            ],
            providerID: "test"
        )

        XCTAssertEqual(merged.inputsByNodeID["a"]?.request.threadContext.totalMessages, 2)
        XCTAssertEqual(split.inputsByNodeID["a"]?.request.threadContext.totalMessages, 1)
        XCTAssertEqual(split.inputsByNodeID["b"]?.request.threadContext.totalMessages, 1)
        XCTAssertNotEqual(merged.inputsByNodeID["a"]?.fingerprint,
                          split.inputsByNodeID["a"]?.fingerprint)
        XCTAssertNotEqual(merged.inputsByNodeID["b"]?.fingerprint,
                          split.inputsByNodeID["b"]?.fingerprint)
    }

    func testStandaloneMessageHasPositionOneAndNoNeighbours() {
        let build = ThreadSummaryContextBuilder.build(
            sources: [makeSource(id: "solo", date: 10, automaticThreadID: "solo")],
            providerID: "test"
        )
        let context = build.inputsByNodeID["solo"]?.request.threadContext

        XCTAssertEqual(context?.position, 1)
        XCTAssertEqual(context?.totalMessages, 1)
        XCTAssertNil(context?.previousMessage)
        XCTAssertNil(context?.nextMessage)
    }

    func testGraphTitleInputCanonicalizesSummaryWhitespaceForStableFingerprint() throws {
        let build = ThreadSummaryContextBuilder.build(
            sources: [makeSource(id: "a", date: 10, automaticThreadID: "reply")],
            providerID: "summary-provider"
        )
        let nodeInput = try XCTUnwrap(build.inputsByNodeID["a"])
        let revision = try XCTUnwrap(build.threadRevisionsByThreadID[nodeInput.effectiveThreadID])
        let first = GraphTitleGenerationInputBuilder.make(
            nodeInput: nodeInput,
            summary: "Confirms   the\nFriday rollout.",
            summaryGenerationID: "generation",
            threadRevision: revision,
            providerID: "title-provider"
        )
        let second = GraphTitleGenerationInputBuilder.make(
            nodeInput: nodeInput,
            summary: "Confirms the Friday rollout.",
            summaryGenerationID: "generation",
            threadRevision: revision,
            providerID: "title-provider"
        )

        XCTAssertEqual(first.request.summary, "Confirms the Friday rollout.")
        XCTAssertEqual(first, second)
    }

    func testRebuildCoordinatorRetainsWholePriorBatchWhenOneGenerationFails() async throws {
        let defaults = UserDefaults(suiteName: "ThreadSummaryCacheTests-\(UUID().uuidString)")!
        let store = MessageStore(userDefaults: defaults, storeType: NSInMemoryStoreType)
        let oldEntries = ["a", "b"].map { id in
            SummaryCacheEntry(scope: .emailNode,
                              scopeID: id,
                              summaryText: "Old \(id)",
                              generatedAt: Date(timeIntervalSince1970: 10),
                              fingerprint: "old-\(id)",
                              provider: "old")
        }
        try await store.upsertSummaries(oldEntries)
        let build = ThreadSummaryContextBuilder.build(
            sources: [
                makeSource(id: "a", date: 10, automaticThreadID: "reply"),
                makeSource(id: "b", date: 20, automaticThreadID: "reply")
            ],
            providerID: "test"
        )
        let coordinator = ThreadSummaryRebuildCoordinator(store: store)
        let generation = await coordinator.beginGeneration()
        let provider = SequencedSummaryProvider(failOnEmailCall: 2)

        do {
            _ = try await coordinator.rebuildThread(inputs: Array(build.inputsByNodeID.values),
                                                    provider: provider,
                                                    providerID: "test",
                                                    generation: generation) { _, _ in }
            XCTFail("Expected the second generation to fail")
        } catch {
            // Expected: persistence happens only after every node succeeds.
        }

        let persisted = try await store.fetchSummaries(scope: .emailNode, ids: ["a", "b"])
        let byID = Dictionary(uniqueKeysWithValues: persisted.map { ($0.scopeID, $0.summaryText) })
        XCTAssertEqual(byID["a"], "Old a")
        XCTAssertEqual(byID["b"], "Old b")
    }

    func testRebuildCoordinatorDiscardsSupersededGeneration() async throws {
        let defaults = UserDefaults(suiteName: "ThreadSummaryCacheTests-\(UUID().uuidString)")!
        let store = MessageStore(userDefaults: defaults, storeType: NSInMemoryStoreType)
        let build = ThreadSummaryContextBuilder.build(
            sources: [makeSource(id: "a", date: 10, automaticThreadID: "reply")],
            providerID: "test"
        )
        let coordinator = ThreadSummaryRebuildCoordinator(store: store)
        let generation = await coordinator.beginGeneration()
        let provider = SequencedSummaryProvider(delayNanoseconds: 120_000_000)
        let task = Task {
            try await coordinator.rebuildThread(inputs: Array(build.inputsByNodeID.values),
                                                provider: provider,
                                                providerID: "test",
                                                generation: generation) { _, _ in }
        }

        try await Task.sleep(nanoseconds: 20_000_000)
        await coordinator.invalidate()

        do {
            _ = try await task.value
            XCTFail("Expected the superseded generation to be cancelled")
        } catch is CancellationError {
            // Expected.
        }
        let persisted = try await store.fetchSummaries(scope: .emailNode, ids: ["a"])
        XCTAssertTrue(persisted.isEmpty)
    }

    private func makeSource(id: String,
                            effectiveThreadID: String = "effective-thread",
                            date: TimeInterval,
                            automaticThreadID: String,
                            isManualAttachment: Bool = false) -> ThreadSummaryMessageSource {
        ThreadSummaryMessageSource(nodeID: id,
                                   cacheKey: id,
                                   effectiveThreadID: effectiveThreadID,
                                   automaticThreadID: automaticThreadID,
                                   messageID: id,
                                   subject: "Subject \(id)",
                                   body: "Body \(id)",
                                   contextSnippet: "Context \(id)",
                                   date: Date(timeIntervalSince1970: date),
                                   isManualAttachment: isManualAttachment)
    }

    @MainActor
    func testCachedNodeSummaryBypassesGenerationOnSecondRun() async throws {
        let defaults = UserDefaults(suiteName: "ThreadSummaryCacheTests-\(UUID().uuidString)")!
        let store = MessageStore(userDefaults: defaults, storeType: NSInMemoryStoreType)
        let provider = TestSummaryProvider(emailResult: "Generated")
        let capability = EmailSummaryCapability(provider: provider,
                                                statusMessage: "Ready",
                                                providerID: "test")
        let settings = AutoRefreshSettings()
        let inspectorSettings = InspectorViewSettings()
        let pinnedFolderSettings = PinnedFolderSettings()
        let viewModel = ThreadCanvasViewModel(settings: settings,
                                              inspectorSettings: inspectorSettings,
                                              pinnedFolderSettings: pinnedFolderSettings,
                                              store: store,
                                              summaryCapability: capability,
                                              folderSummaryDebounceInterval: 0)

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let message = EmailMessage(messageID: "<a>",
                                   mailboxID: "inbox",
                                   accountName: "",
                                   subject: "Latest",
                                   from: "a@example.com",
                                   to: "me@example.com",
                                   date: now,
                                   snippet: "Body",
                                   isUnread: false,
                                   inReplyTo: nil,
                                   references: [])
        let threader = JWZThreader()
        let result = threader.buildThreads(from: [message])
        guard let root = result.roots.first else {
            XCTFail("Expected a thread root")
            return
        }

        viewModel.applyRethreadResultForTesting(roots: [root])
        try await waitForNodeSummaryRefresh(viewModel)
        XCTAssertEqual(provider.emailCallCount, 1)

        provider.resetCounts()
        viewModel.applyRethreadResultForTesting(roots: [root])
        try await waitForNodeSummaryRefresh(viewModel)
        XCTAssertEqual(provider.emailCallCount, 0)
    }

    @MainActor
    func testBatchRegenerationNotificationReloadsIdenticalTextGenerationID() async throws {
        let defaults = UserDefaults(suiteName: "ThreadSummaryCacheTests-\(UUID().uuidString)")!
        let store = MessageStore(userDefaults: defaults, storeType: NSInMemoryStoreType)
        let capability = EmailSummaryCapability(provider: nil,
                                                statusMessage: "Unavailable",
                                                providerID: "test")
        let viewModel = ThreadCanvasViewModel(settings: AutoRefreshSettings(),
                                              store: store,
                                              summaryCapability: capability,
                                              folderSummaryDebounceInterval: 0)
        let message = EmailMessage(messageID: "<same-text>",
                                   mailboxID: "inbox",
                                   accountName: "",
                                   subject: "Same summary",
                                   from: "a@example.com",
                                   to: "me@example.com",
                                   date: Date(timeIntervalSince1970: 1_700_000_000),
                                   snippet: "Body",
                                   isUnread: false,
                                   inReplyTo: nil,
                                   references: [])
        let root = try XCTUnwrap(JWZThreader().buildThreads(from: [message]).roots.first)
        let initial = SummaryCacheEntry(scope: .emailNode,
                                        scopeID: root.id,
                                        summaryText: "Identical generated text",
                                        generatedAt: Date(timeIntervalSince1970: 1_700_000_010),
                                        fingerprint: "same-context",
                                        provider: "test")
        try await store.upsertSummaries([initial])

        viewModel.applyRethreadResultForTesting(roots: [root])
        try await waitForNodeSummaryRefresh(viewModel)
        XCTAssertEqual(viewModel.summaryState(for: root.id)?.generationID,
                       initial.generationID)

        let regenerated = SummaryCacheEntry(scope: .emailNode,
                                            scopeID: root.id,
                                            summaryText: initial.summaryText,
                                            generatedAt: Date(timeIntervalSince1970: 1_700_000_020),
                                            fingerprint: initial.fingerprint,
                                            provider: initial.provider)
        try await store.upsertSummaries([regenerated])
        NotificationCenter.default.post(name: .summaryRegenerationDidComplete,
                                        object: store)
        for _ in 0..<200 {
            if viewModel.summaryState(for: root.id)?.generationID == regenerated.generationID {
                break
            }
            try await Task.sleep(nanoseconds: 25_000_000)
        }

        let reloaded = try XCTUnwrap(viewModel.summaryState(for: root.id))
        XCTAssertEqual(reloaded.text, initial.summaryText)
        XCTAssertEqual(reloaded.generationID, regenerated.generationID)
        XCTAssertNotEqual(reloaded.generationID, initial.generationID)
    }

    @MainActor
    func testNodeSummaryRegeneratesWhenPriorContextChanges() async throws {
        let defaults = UserDefaults(suiteName: "ThreadSummaryCacheTests-\(UUID().uuidString)")!
        let store = MessageStore(userDefaults: defaults, storeType: NSInMemoryStoreType)
        let provider = TestSummaryProvider(emailResult: "Generated")
        let capability = EmailSummaryCapability(provider: provider,
                                                statusMessage: "Ready",
                                                providerID: "test")
        let settings = AutoRefreshSettings()
        let inspectorSettings = InspectorViewSettings()
        let pinnedFolderSettings = PinnedFolderSettings()
        let viewModel = ThreadCanvasViewModel(settings: settings,
                                              inspectorSettings: inspectorSettings,
                                              pinnedFolderSettings: pinnedFolderSettings,
                                              store: store,
                                              summaryCapability: capability,
                                              folderSummaryDebounceInterval: 0)

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let latest = EmailMessage(messageID: "<a>",
                                  mailboxID: "inbox",
                                  accountName: "",
                                  subject: "Latest",
                                  from: "a@example.com",
                                  to: "me@example.com",
                                  date: now,
                                  snippet: "Body",
                                  isUnread: false,
                                  inReplyTo: nil,
                                  references: [])
        let threader = JWZThreader()
        let firstResult = threader.buildThreads(from: [latest])
        guard let firstRoot = firstResult.roots.first else {
            XCTFail("Expected a thread root")
            return
        }

        viewModel.applyRethreadResultForTesting(roots: [firstRoot])
        try await waitForNodeSummaryRefresh(viewModel)
        XCTAssertEqual(provider.emailCallCount, 1)

        let older = EmailMessage(messageID: "<b>",
                                 mailboxID: "inbox",
                                 accountName: "",
                                 subject: "Older",
                                 from: "b@example.com",
                                 to: "me@example.com",
                                 date: Calendar.current.date(byAdding: .day, value: -1, to: now)!,
                                 snippet: "Earlier body",
                                 isUnread: false,
                                 inReplyTo: nil,
                                 references: [])
        let latestWithReply = EmailMessage(messageID: "<a>",
                                           mailboxID: "inbox",
                                           accountName: "",
                                           subject: "Latest",
                                           from: "a@example.com",
                                           to: "me@example.com",
                                           date: now,
                                           snippet: "Body",
                                           isUnread: false,
                                           inReplyTo: older.messageID,
                                           references: [older.messageID])
        let secondResult = threader.buildThreads(from: [latestWithReply, older])
        guard let secondRoot = secondResult.roots.first else {
            XCTFail("Expected a thread root")
            return
        }

        viewModel.applyRethreadResultForTesting(roots: [secondRoot])
        try await waitForNodeSummaryRefresh(viewModel)
        XCTAssertEqual(provider.emailCallCount, 3)
    }

    @MainActor
    func testFolderSummaryDebouncePublishesLatestRefresh() async throws {
        let defaults = UserDefaults(suiteName: "ThreadSummaryCacheTests-\(UUID().uuidString)")!
        let store = MessageStore(userDefaults: defaults, storeType: NSInMemoryStoreType)
        let provider = TestSummaryProvider(emailResult: "Node summary", folderResult: "Folder summary")
        let capability = EmailSummaryCapability(provider: provider,
                                                statusMessage: "Ready",
                                                providerID: "test")
        let settings = AutoRefreshSettings()
        let inspectorSettings = InspectorViewSettings()
        let pinnedFolderSettings = PinnedFolderSettings()
        let viewModel = ThreadCanvasViewModel(settings: settings,
                                              inspectorSettings: inspectorSettings,
                                              pinnedFolderSettings: pinnedFolderSettings,
                                              store: store,
                                              summaryCapability: capability,
                                              folderSummaryDebounceInterval: 0.1)

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let messageA = EmailMessage(messageID: "<a>",
                                    mailboxID: "inbox",
                                    accountName: "",
                                    subject: "Latest",
                                    from: "a@example.com",
                                    to: "me@example.com",
                                    date: now,
                                    snippet: "Body",
                                    isUnread: false,
                                    inReplyTo: nil,
                                    references: [])
        let threader = JWZThreader()
        let result = threader.buildThreads(from: [messageA])
        guard let root = result.roots.first else {
            XCTFail("Expected a thread root")
            return
        }

        let nodeCache = SummaryCacheEntry(scope: .emailNode,
                                          scopeID: root.id,
                                          summaryText: "Node summary",
                                          generatedAt: now,
                                          fingerprint: "node-fingerprint",
                                          provider: "test")
        try await store.upsertSummaries([nodeCache])

        let folderID = "folder-1"
        let effectiveThreadID = root.message.threadID ?? root.id
        let folderA = ThreadFolder(id: folderID,
                                   title: "First",
                                   color: ThreadFolderColor(red: 0.2, green: 0.3, blue: 0.4, alpha: 1),
                                   threadIDs: Set([effectiveThreadID]),
                                   parentID: nil)
        viewModel.applyRethreadResultForTesting(roots: [root],
                                                folders: [folderA])

        try await Task.sleep(nanoseconds: 50_000_000)

        let folderB = ThreadFolder(id: folderID,
                                   title: "Second",
                                   color: folderA.color,
                                   threadIDs: folderA.threadIDs,
                                   parentID: nil)
        viewModel.applyRethreadResultForTesting(roots: [root],
                                                folders: [folderB])

        for _ in 0..<100 where provider.folderRequests.last?.title != "Second" {
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        XCTAssertTrue((1...2).contains(provider.folderCallCount))
        XCTAssertEqual(provider.folderRequests.last?.title, "Second")
        XCTAssertEqual(viewModel.folderSummaryState(for: folderID)?.text, "Folder summary")
    }

    @MainActor
    private func waitForNodeSummaryRefresh(_ viewModel: ThreadCanvasViewModel) async throws {
        for _ in 0..<400 {
            if !viewModel.isNodeSummaryRefreshPendingForTesting {
                return
            }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTFail("Timed out waiting for the node-summary refresh task")
    }
}

private nonisolated final class TestSummaryProvider: EmailSummaryProviding, @unchecked Sendable {
    private(set) var emailCallCount = 0
    private(set) var folderCallCount = 0
    private(set) var emailRequests: [EmailSummaryRequest] = []
    private(set) var folderRequests: [FolderSummaryRequest] = []

    private let emailResult: String
    private let folderResult: String

    init(emailResult: String, folderResult: String = "") {
        self.emailResult = emailResult
        self.folderResult = folderResult
    }

    func resetCounts() {
        emailCallCount = 0
        folderCallCount = 0
        emailRequests = []
        folderRequests = []
    }

    func summarize(subjects: [String]) async throws -> String {
        return ""
    }

    func summarizeEmail(_ request: EmailSummaryRequest) async throws -> String {
        emailCallCount += 1
        emailRequests.append(request)
        return emailResult
    }

    func summarizeFolder(_ request: FolderSummaryRequest) async throws -> String {
        folderCallCount += 1
        folderRequests.append(request)
        return folderResult
    }
}

private enum SequencedSummaryProviderError: Error {
    case expectedFailure
}

private nonisolated final class SequencedSummaryProvider: EmailSummaryProviding, @unchecked Sendable {
    private var emailCallCount = 0
    private let failOnEmailCall: Int?
    private let delayNanoseconds: UInt64

    init(failOnEmailCall: Int? = nil, delayNanoseconds: UInt64 = 0) {
        self.failOnEmailCall = failOnEmailCall
        self.delayNanoseconds = delayNanoseconds
    }

    func summarize(subjects: [String]) async throws -> String { "" }

    func summarizeEmail(_ request: EmailSummaryRequest) async throws -> String {
        if delayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: delayNanoseconds)
        }
        emailCallCount += 1
        if emailCallCount == failOnEmailCall {
            throw SequencedSummaryProviderError.expectedFailure
        }
        return "New \(request.subject)"
    }

    func summarizeFolder(_ request: FolderSummaryRequest) async throws -> String { "" }
}
