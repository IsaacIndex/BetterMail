import CoreData
import XCTest
@testable import BetterMail

@MainActor
final class ThreadFolderColorTests: XCTestCase {
    func testDefaultNewFolder_usesMutedAnchor() {
        XCTAssertEqual(
            ThreadFolderColor.defaultNewFolder,
            ThreadFolderColor(red: 0.663, green: 0.502, blue: 0.431, alpha: 1.0)
        )
    }

    func testRecalibrated_prefersUnusedSiblingPaletteColor() {
        let currentFolder = ThreadFolder(id: "current",
                                         title: "Current",
                                         color: ThreadFolderColor.defaultNewFolder,
                                         threadIDs: ["thread-1"],
                                         parentID: "parent")
        let siblingA = ThreadFolder(id: "sibling-a",
                                    title: "Sibling A",
                                    color: ThreadFolderColor(red: 0.620, green: 0.455, blue: 0.500, alpha: 1.0),
                                    threadIDs: ["thread-2"],
                                    parentID: "parent")
        let siblingB = ThreadFolder(id: "sibling-b",
                                    title: "Sibling B",
                                    color: ThreadFolderColor.defaultNewFolder,
                                    threadIDs: ["thread-3"],
                                    parentID: "parent")

        let recalibrated = ThreadFolderColor.recalibrated(for: currentFolder, among: [currentFolder, siblingA, siblingB])

        XCTAssertEqual(
            recalibrated,
            ThreadFolderColor(red: 0.604, green: 0.561, blue: 0.384, alpha: 1.0)
        )
    }

    func testAddFolderForSelection_usesDefaultMutedColor() async throws {
        let defaults = UserDefaults(suiteName: "ThreadFolderColorTests-\(UUID().uuidString)")!
        let store = MessageStore(userDefaults: defaults, storeType: NSInMemoryStoreType)
        let viewModel = ThreadCanvasViewModel(settings: AutoRefreshSettings(),
                                              inspectorSettings: InspectorViewSettings(),
                                              store: store)
        let message = EmailMessage(messageID: "msg-1",
                                   mailboxID: "Inbox",
                                   accountName: "Work",
                                   subject: "Color check",
                                   from: "sender@example.com",
                                   to: "me@example.com",
                                   date: Date(),
                                   snippet: "",
                                   isUnread: false,
                                   inReplyTo: nil,
                                   references: [],
                                   threadID: "thread-1")

        viewModel.applyRethreadResultForTesting(roots: [ThreadNode(message: message)])
        viewModel.selectNode(id: message.messageID)
        viewModel.addFolderForSelection()
        try await Task.sleep(nanoseconds: 250_000_000)

        let folders = try await store.fetchThreadFolders()
        XCTAssertEqual(folders.first?.color, ThreadFolderColor.defaultNewFolder)
    }

    func testRecalibratedColor_updatesDescendantsAcrossAllLevels() async throws {
        let defaults = UserDefaults(suiteName: "ThreadFolderColorTests-\(UUID().uuidString)")!
        let store = MessageStore(userDefaults: defaults, storeType: NSInMemoryStoreType)
        let viewModel = ThreadCanvasViewModel(settings: AutoRefreshSettings(),
                                              inspectorSettings: InspectorViewSettings(),
                                              store: store)
        let root = ThreadFolder(id: "root",
                                title: "Root",
                                color: ThreadFolderColor.defaultNewFolder,
                                threadIDs: ["thread-root"],
                                parentID: nil)
        let child = ThreadFolder(id: "child",
                                 title: "Child",
                                 color: ThreadFolderColor(red: 0.620, green: 0.455, blue: 0.500, alpha: 1.0),
                                 threadIDs: ["thread-child"],
                                 parentID: "root")
        let grandchild = ThreadFolder(id: "grandchild",
                                      title: "Grandchild",
                                      color: ThreadFolderColor.defaultNewFolder,
                                      threadIDs: ["thread-grandchild"],
                                      parentID: "child")

        viewModel.applyRethreadResultForTesting(roots: [], folders: [root, child, grandchild])

        let selectedColor = viewModel.recalibratedColor(for: "root")
        try await Task.sleep(nanoseconds: 250_000_000)

        let savedFolders = try await store.fetchThreadFolders()
        let savedByID = Dictionary(uniqueKeysWithValues: savedFolders.map { ($0.id, $0) })

        XCTAssertEqual(selectedColor,
                       ThreadFolderColor(red: 0.604, green: 0.561, blue: 0.384, alpha: 1.0))
        XCTAssertEqual(savedByID["child"]?.color,
                       ThreadFolderColor(red: 0.431, green: 0.584, blue: 0.502, alpha: 1.0))
        XCTAssertEqual(savedByID["grandchild"]?.color,
                       ThreadFolderColor(red: 0.424, green: 0.525, blue: 0.671, alpha: 1.0))
    }
}
