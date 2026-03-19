# Action Items Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an Action Items view where users right-click any canvas thread card to tag it, then see all tagged emails grouped by folder in a dedicated default sidebar view.

**Architecture:** A new `ActionItemEntity` in Core Data stores a snapshot of the message ID, folder ID, and 3 AI tags at tag time. `ThreadCanvasViewModel` exposes `actionItemIDs: Set<String>` so the canvas context menu can show the correct toggle label. `ActionItemsView` fetches from `MessageStore` and groups by folder ID.

**Tech Stack:** SwiftUI, Core Data (programmatic model), `@MainActor`, `async/await`

---

## File Map

| File | Status | Responsibility |
|------|--------|---------------|
| `BetterMail/Sources/Models/ActionItem.swift` | **Create** | `ActionItem` model struct |
| `BetterMail/Sources/Storage/MessageStore.swift` | **Modify** | Add `ActionItemEntity` to `makeModel()` + 4 CRUD methods |
| `BetterMail/Sources/Models/MailboxHierarchy.swift` | **Modify** | Add `.actionItems` case to `MailboxScope` |
| `BetterMail/Sources/ViewModels/ThreadCanvasViewModel.swift` | **Modify** | `@Published actionItemIDs`, `addActionItem`, `removeActionItem`, `fetchActionItems` |
| `BetterMail/Sources/UI/ThreadCanvasView.swift` | **Modify** | Add `.contextMenu` to node wrapper at tap-gesture site |
| `BetterMail/Sources/UI/ActionItemsView.swift` | **Create** | Grouped flat-list view |
| `BetterMail/Sources/UI/MailboxSidebarView.swift` | **Modify** | Add Action Items row above All Emails |
| `BetterMail/ContentView.swift` | **Modify** | Default sidebar selection to `.actionItems` |
| `Tests/ActionItemTests.swift` | **Create** | 6 unit tests using in-memory Core Data (note: spec incorrectly lists `BetterMailTests/`; correct path is `Tests/`, matching all other test files) |

---

## Task 1: ActionItem model struct

**Files:**
- Create: `BetterMail/Sources/Models/ActionItem.swift`

- [ ] **Step 1: Create the model**

```swift
// BetterMail/Sources/Models/ActionItem.swift
import Foundation

// Note: subject, from, date are snapshotted at tag time so ActionItemsView
// can render the list without re-fetching EmailMessage from Core Data.
// This intentionally duplicates a small amount of message data for display convenience.
internal struct ActionItem: Identifiable, Hashable {
    internal let id: String          // matches EmailMessage.messageID
    internal let threadID: String
    internal let subject: String     // snapshotted at tag time
    internal let from: String        // snapshotted at tag time
    internal let date: Date          // snapshotted at tag time
    internal let folderID: String?
    internal let tags: [String]      // snapshotted at tag time, up to 3 (AI-generated)
    internal var isDone: Bool
    internal let addedAt: Date
}
```

- [ ] **Step 2: Commit**

```bash
git add BetterMail/Sources/Models/ActionItem.swift
git commit -m "feat: add ActionItem model struct"
```

---

## Task 2: ActionItemEntity in Core Data + MessageStore CRUD

**Files:**
- Modify: `BetterMail/Sources/Storage/MessageStore.swift`

The model is built programmatically in `makeModel()`. Pattern to follow: see how `ManualThreadGroupEntity` is added (lines ~904–960 in MessageStore.swift). You need to add an `ActionItemEntity` NSEntityDescription and a matching `NSManagedObject` subclass, then add 4 methods.

- [ ] **Step 1: Write the failing tests first**

Create `Tests/ActionItemTests.swift`:

```swift
import XCTest
@testable import BetterMail

final class ActionItemTests: XCTestCase {

    // Matches the pattern used throughout the test suite (e.g. MessageStoreBoundaryTests).
    // A unique UserDefaults suite name isolates each test from shared defaults state.
    private func makeStore() -> MessageStore {
        let defaults = UserDefaults(suiteName: "ActionItemTests-\(UUID().uuidString)")!
        return MessageStore(userDefaults: defaults, storeType: NSInMemoryStoreType)
    }

    private func makeMessage(id: String = "msg-1") -> EmailMessage {
        EmailMessage(messageID: id,
                     mailboxID: "inbox",
                     accountName: "Test",
                     subject: "Test subject",
                     from: "sender@example.com",
                     to: "me@example.com",
                     date: Date(),
                     snippet: "snippet",
                     isUnread: true,
                     inReplyTo: nil,
                     references: [])
    }

    func test_addActionItem_newMessage_persistsRecord() async throws {
        let store = makeStore()
        let msg = makeMessage()
        await store.addActionItem(for: msg, folderID: "folder-1", tags: ["Tag A", "Tag B", "Tag C"])
        let items = await store.fetchActionItems()
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].id, msg.messageID)
        XCTAssertEqual(items[0].folderID, "folder-1")
        XCTAssertEqual(items[0].tags, ["Tag A", "Tag B", "Tag C"])
        XCTAssertFalse(items[0].isDone)
    }

    func test_addActionItem_duplicateMessage_isIdempotent() async throws {
        let store = makeStore()
        let msg = makeMessage()
        await store.addActionItem(for: msg, folderID: nil, tags: [])
        await store.addActionItem(for: msg, folderID: nil, tags: [])
        let items = await store.fetchActionItems()
        XCTAssertEqual(items.count, 1)
    }

    func test_toggleActionItemDone_existingItem_flipsFlag() async throws {
        let store = makeStore()
        let msg = makeMessage()
        await store.addActionItem(for: msg, folderID: nil, tags: [])
        await store.toggleActionItemDone(msg.messageID)
        let items = await store.fetchActionItems()
        XCTAssertTrue(items[0].isDone)
        // Toggle back
        await store.toggleActionItemDone(msg.messageID)
        let items2 = await store.fetchActionItems()
        XCTAssertFalse(items2[0].isDone)
    }

    func test_removeActionItem_existingItem_deletesRecord() async throws {
        let store = makeStore()
        let msg = makeMessage()
        await store.addActionItem(for: msg, folderID: nil, tags: [])
        await store.removeActionItem(for: msg)
        let items = await store.fetchActionItems()
        XCTAssertTrue(items.isEmpty)
    }

    func test_fetchActionItems_groupedByFolder_correctGroups() async throws {
        let store = makeStore()
        let msg1 = makeMessage(id: "msg-1")
        let msg2 = makeMessage(id: "msg-2")
        let msg3 = makeMessage(id: "msg-3")
        await store.addActionItem(for: msg1, folderID: "folder-A", tags: [])
        await store.addActionItem(for: msg2, folderID: "folder-A", tags: [])
        await store.addActionItem(for: msg3, folderID: "folder-B", tags: [])
        let items = await store.fetchActionItems()
        let groupA = items.filter { $0.folderID == "folder-A" }
        let groupB = items.filter { $0.folderID == "folder-B" }
        XCTAssertEqual(groupA.count, 2)
        XCTAssertEqual(groupB.count, 1)
    }

    func test_actionItemTags_snapshotAtTagTime_arePreserved() async throws {
        let store = makeStore()
        let msg = makeMessage()
        let originalTags = ["Alpha", "Beta", "Gamma"]
        await store.addActionItem(for: msg, folderID: nil, tags: originalTags)
        let items = await store.fetchActionItems()
        XCTAssertEqual(items[0].tags, originalTags)
    }
}
```

- [ ] **Step 2: Run tests — expect compilation failure** (entity and methods don't exist yet)

```bash
xcodebuild test \
  -project BetterMail.xcodeproj \
  -scheme BetterMail \
  -destination 'platform=macOS' \
  -only-testing:BetterMailTests/ActionItemTests \
  > /tmp/xcodebuild.log 2>&1
grep -n "error:" /tmp/xcodebuild.log | head -20
```

Note: `BetterMailTests` is the Xcode test target name (matches `-only-testing:BetterMailTests/ThreadCanvasLayoutTests` in CLAUDE.md). The source file lives in `Tests/ActionItemTests.swift` but the target is `BetterMailTests`.

- [ ] **Step 3: Add ActionItemEntity NSManagedObject subclass**

At the bottom of `MessageStore.swift`, after the existing entity classes (e.g. after `ManualThreadGroupEntity`). Follow the exact pattern used by `MessageEntity` (line ~1274): `@objc(ClassName)` attribute, then the class, then a **separate extension** with `@nonobjc class func fetchRequest()`.

```swift
@objc(ActionItemEntity)
private final class ActionItemEntity: NSManagedObject {
    @NSManaged var messageID: String
    @NSManaged var threadID: String
    @NSManaged var subject: String
    @NSManaged var fromAddress: String
    @NSManaged var date: Date
    @NSManaged var folderID: String?
    @NSManaged var tagsData: Data?   // JSON-encoded [String]
    @NSManaged var isDone: Bool
    @NSManaged var addedAt: Date

    func toModel() -> ActionItem? {
        let tags: [String]
        if let data = tagsData,
           let decoded = try? JSONDecoder().decode([String].self, from: data) {
            tags = decoded
        } else {
            tags = []
        }
        return ActionItem(id: messageID,
                          threadID: threadID,
                          subject: subject,
                          from: fromAddress,
                          date: date,
                          folderID: folderID,
                          tags: tags,
                          isDone: isDone,
                          addedAt: addedAt)
    }
}

private extension ActionItemEntity {
    @nonobjc class func fetchRequest() -> NSFetchRequest<ActionItemEntity> {
        NSFetchRequest<ActionItemEntity>(entityName: "ActionItemEntity")
    }
}
```

- [ ] **Step 4: Register ActionItemEntity in makeModel()**

Inside `makeModel()`, after the last existing entity block and before `model.entities = [...]`, add:

```swift
let actionItemEntity = NSEntityDescription()
actionItemEntity.name = "ActionItemEntity"
actionItemEntity.managedObjectClassName = NSStringFromClass(ActionItemEntity.self)

let aiMessageIDAttr = NSAttributeDescription()
aiMessageIDAttr.name = "messageID"
aiMessageIDAttr.attributeType = .stringAttributeType
aiMessageIDAttr.isOptional = false
aiMessageIDAttr.isIndexed = true

let aiThreadIDAttr = NSAttributeDescription()
aiThreadIDAttr.name = "threadID"
aiThreadIDAttr.attributeType = .stringAttributeType
aiThreadIDAttr.isOptional = false

let aiSubjectAttr = NSAttributeDescription()
aiSubjectAttr.name = "subject"
aiSubjectAttr.attributeType = .stringAttributeType
aiSubjectAttr.isOptional = false

let aiFromAttr = NSAttributeDescription()
aiFromAttr.name = "fromAddress"
aiFromAttr.attributeType = .stringAttributeType
aiFromAttr.isOptional = false

let aiDateAttr = NSAttributeDescription()
aiDateAttr.name = "date"
aiDateAttr.attributeType = .dateAttributeType
aiDateAttr.isOptional = false

let aiFolderIDAttr = NSAttributeDescription()
aiFolderIDAttr.name = "folderID"
aiFolderIDAttr.attributeType = .stringAttributeType
aiFolderIDAttr.isOptional = true

let aiTagsAttr = NSAttributeDescription()
aiTagsAttr.name = "tagsData"
aiTagsAttr.attributeType = .binaryDataAttributeType
aiTagsAttr.isOptional = true

let aiIsDoneAttr = NSAttributeDescription()
aiIsDoneAttr.name = "isDone"
aiIsDoneAttr.attributeType = .booleanAttributeType
aiIsDoneAttr.isOptional = false
aiIsDoneAttr.defaultValue = false

let aiAddedAtAttr = NSAttributeDescription()
aiAddedAtAttr.name = "addedAt"
aiAddedAtAttr.attributeType = .dateAttributeType
aiAddedAtAttr.isOptional = false

actionItemEntity.properties = [
    aiMessageIDAttr,
    aiThreadIDAttr,
    aiSubjectAttr,
    aiFromAttr,
    aiDateAttr,
    aiFolderIDAttr,
    aiTagsAttr,
    aiIsDoneAttr,
    aiAddedAtAttr
]
```

Then add `actionItemEntity` to the `model.entities = [...]` array at the end of `makeModel()`.

- [ ] **Step 5: Add the CRUD methods to MessageStore**

The `NSPersistentContainer` extension (line ~1487) declares `performBackgroundTask` as `async throws`. Use `try? await` on writes (swallow non-critical errors) and `(try? await ...) ?? []` on fetch. Do NOT use `withCheckedContinuation` — that pattern doesn't exist in this codebase.

Add after `fetchMessages` methods:

```swift
// Note: `tags:` extends the spec's 2-param signature to support tag snapshotting (spec §Tag Persistence).
internal func addActionItem(for message: EmailMessage,
                             folderID: String?,
                             tags: [String]) async {
    _ = try? await container.performBackgroundTask { context -> Void in
        let request = ActionItemEntity.fetchRequest()
        request.predicate = NSPredicate(format: "messageID == %@", message.messageID)
        let existing = (try? context.fetch(request)) ?? []
        guard existing.isEmpty else { return } // idempotent
        let entity = ActionItemEntity(context: context)
        entity.messageID = message.messageID
        entity.threadID = message.threadID ?? message.messageID
        entity.subject = message.subject
        entity.fromAddress = message.from
        entity.date = message.date
        entity.folderID = folderID
        entity.tagsData = try? JSONEncoder().encode(Array(tags.prefix(3)))
        entity.isDone = false
        entity.addedAt = Date()
        try context.save()
    }
}

internal func removeActionItem(for message: EmailMessage) async {
    _ = try? await container.performBackgroundTask { context -> Void in
        let request = ActionItemEntity.fetchRequest()
        request.predicate = NSPredicate(format: "messageID == %@", message.messageID)
        let entities = (try? context.fetch(request)) ?? []
        entities.forEach { context.delete($0) }
        try context.save()
    }
}

internal func toggleActionItemDone(_ messageID: String) async {
    _ = try? await container.performBackgroundTask { context -> Void in
        let request = ActionItemEntity.fetchRequest()
        request.predicate = NSPredicate(format: "messageID == %@", messageID)
        guard let entity = try? context.fetch(request).first else { return }
        entity.isDone.toggle()
        try context.save()
    }
}

internal func fetchActionItems() async -> [ActionItem] {
    (try? await container.performBackgroundTask { context -> [ActionItem] in
        let request = ActionItemEntity.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(key: "addedAt", ascending: false)]
        return try context.fetch(request).compactMap { $0.toModel() }
    }) ?? []
}

internal func fetchActionItemIDs() async -> Set<String> {
    Set(await fetchActionItems().map(\.id))
}
```

- [ ] **Step 6: Run tests — all 6 should pass**

```bash
xcodebuild test \
  -project BetterMail.xcodeproj \
  -scheme BetterMail \
  -destination 'platform=macOS' \
  -only-testing:BetterMailTests/ActionItemTests \
  > /tmp/xcodebuild.log 2>&1
grep -n "error:\|TEST FAILED\|TEST SUCCEEDED" /tmp/xcodebuild.log | head -20
```

Expected: all 6 tests pass, no errors.

- [ ] **Step 7: Build check**

```bash
xcodebuild \
  -project BetterMail.xcodeproj \
  -scheme BetterMail \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  build > /tmp/xcodebuild.log 2>&1
grep -n "error:\|BUILD FAILED" /tmp/xcodebuild.log || echo "BUILD SUCCEEDED"
```

- [ ] **Step 8: Commit**

```bash
git add BetterMail/Sources/Storage/MessageStore.swift Tests/ActionItemTests.swift
git commit -m "feat: add ActionItemEntity to Core Data and MessageStore CRUD methods"
```

---

## Task 3: Add .actionItems to MailboxScope

**Files:**
- Modify: `BetterMail/Sources/Models/MailboxHierarchy.swift`

- [ ] **Step 1: Add the new case**

In `MailboxHierarchy.swift`, add `.actionItems` to the `MailboxScope` enum. It needs no associated values:

```swift
internal enum MailboxScope: Hashable {
    case actionItems        // ← add this as the first case
    case allEmails
    case allFolders
    case allInboxes
    case mailboxFolder(account: String, path: String)
    // ...
}
```

Update the `mailboxPath` and `accountName` switch statements to handle `.actionItems` the same way as `.allEmails` (return `"inbox"` and `nil` respectively).

- [ ] **Step 2: Fix all exhaustive switch sites (confirmed by grep)**

These are the known switch sites that need updating:

**`MailboxHierarchy.swift` — `mailboxPath` computed var (~line 11):**
```swift
case .actionItems, .allEmails, .allFolders, .allInboxes:
    return "inbox"
```

**`MailboxHierarchy.swift` — `accountName` computed var (~line 20):**
```swift
case .actionItems, .allEmails, .allFolders, .allInboxes:
    return nil
```

**`ThreadCanvasViewModel.swift` ~line 4287 — scope → account lookup:**
```swift
case .actionItems, .allEmails, .allFolders, .allInboxes:
    // existing behaviour unchanged
```

**`ThreadCanvasViewModel.swift` ~line 4391 — `activeMailboxFetchTarget` computed var:**
When `.actionItems` is active, `ContentView` shows `ActionItemsView` (not the canvas), so this var is never called. Add to satisfy exhaustiveness — fall through to the same return as `.allEmails`:
```swift
case .actionItems, .allEmails, .allFolders, .allInboxes:
    return (mailbox: "inbox", account: nil)
```

**`ThreadCanvasViewModel.swift` ~line 4400 — `activeMailboxStoreFilter` computed var:**
Same reasoning — not called when `.actionItems` is active. Add `.actionItems` alongside `.allEmails, .allFolders`:
```swift
case .actionItems, .allEmails, .allFolders:
    return (mailbox: nil, account: nil, includeAllInboxesAliases: false)
```

The `selectMailboxScope` at line ~2136 uses `!=` equality, not a switch — no change needed there.

- [ ] **Step 2b: Build check**

```bash
xcodebuild \
  -project BetterMail.xcodeproj \
  -scheme BetterMail \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  build > /tmp/xcodebuild.log 2>&1
grep -n "error:" /tmp/xcodebuild.log | head -20
```

If the compiler flags additional switch sites not listed above, add `.actionItems` alongside `.allEmails` in each case.

- [ ] **Step 3: Commit**

```bash
git add BetterMail/Sources/Models/MailboxHierarchy.swift
git commit -m "feat: add .actionItems case to MailboxScope"
```

---

## Task 4: ThreadCanvasViewModel — actionItemIDs + action methods

**Files:**
- Modify: `BetterMail/Sources/ViewModels/ThreadCanvasViewModel.swift`

- [ ] **Step 1: Add @Published actionItemIDs**

Near the other `@Published` properties (around line 568), add:

```swift
@Published internal private(set) var actionItemIDs: Set<String> = []
```

- [ ] **Step 2: Add action methods**

Near `selectMailboxScope` or the other action methods, add:

```swift
internal func addActionItem(message: EmailMessage, folderID: String?, tags: [String]) {
    Task {
        await MessageStore.shared.addActionItem(for: message, folderID: folderID, tags: tags)
        await refreshActionItemIDs()
    }
}

internal func removeActionItem(message: EmailMessage) {
    Task {
        await MessageStore.shared.removeActionItem(for: message)
        await refreshActionItemIDs()
    }
}

internal func toggleActionItemDone(_ messageID: String) {
    Task {
        await MessageStore.shared.toggleActionItemDone(messageID)
        await refreshActionItemIDs()
    }
}

@MainActor
private func refreshActionItemIDs() async {
    actionItemIDs = await MessageStore.shared.fetchActionItemIDs()
}
```

- [ ] **Step 3: Load actionItemIDs on start**

`start()` (line ~990) contains several independent `Task { }` calls — there is no single enclosing Task block. Add a **new** Task call after the existing ones:

```swift
internal func start() {
    guard !didStart else { return }
    didStart = true
    // ... existing lines ...
    Task { await loadCachedMessages() }
    refreshMailboxHierarchy()
    refreshNow()
    applyAutoRefreshSettings()
    Task { await refreshActionItemIDs() }  // ← add this line at the end
}
```

- [ ] **Step 4: Build check**

```bash
xcodebuild \
  -project BetterMail.xcodeproj \
  -scheme BetterMail \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  build > /tmp/xcodebuild.log 2>&1
grep -n "error:\|BUILD FAILED" /tmp/xcodebuild.log || echo "BUILD SUCCEEDED"
```

- [ ] **Step 5: Commit**

```bash
git add BetterMail/Sources/ViewModels/ThreadCanvasViewModel.swift
git commit -m "feat: add actionItemIDs and action methods to ThreadCanvasViewModel"
```

---

## Task 5: Context menu on thread canvas nodes

**Files:**
- Modify: `BetterMail/Sources/UI/ThreadCanvasView.swift`

The thread node cards don't have a context menu yet. The tap gesture is applied at the call site (around line 914), not inside `ThreadCanvasNodeView`. Add the context menu modifier at the same level as `.onTapGesture`.

- [ ] **Step 1: Add context menu to node wrapper**

In the section that applies `.onTapGesture` to each canvas node (around line 914), add `.contextMenu` after `.onTapGesture`:

```swift
.onTapGesture {
    viewModel.selectNode(id: nodeData.node.id, additive: isCommandClick())
}
.contextMenu {
    let message = nodeData.node.message
    let isActionItem = viewModel.actionItemIDs.contains(message.messageID)
    let folderID = viewModel.folderMembershipByThreadID[nodeData.node.threadID]
    let tags = nodeData.tags  // already on VisibleCanvasNodeData

    Button {
        if isActionItem {
            viewModel.removeActionItem(message: message)
        } else {
            viewModel.addActionItem(message: message,
                                    folderID: folderID,
                                    tags: tags)
        }
    } label: {
        Label(
            isActionItem
                ? NSLocalizedString("threadcanvas.node.menu.remove_action_item",
                                    comment: "Remove from Action Items")
                : NSLocalizedString("threadcanvas.node.menu.add_action_item",
                                    comment: "Add to Action Items"),
            systemImage: isActionItem ? "checkmark.circle.fill" : "bolt.circle"
        )
    }
}
```

Note: `VisibleCanvasNodeData` already has a `tags: [String]` field (line 935). If the field is named differently (e.g. `timelineTags`), use the actual field name — check the struct definition at line 71.

- [ ] **Step 2: Build check**

```bash
xcodebuild \
  -project BetterMail.xcodeproj \
  -scheme BetterMail \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  build > /tmp/xcodebuild.log 2>&1
grep -n "error:\|BUILD FAILED" /tmp/xcodebuild.log || echo "BUILD SUCCEEDED"
```

- [ ] **Step 3: Commit**

```bash
git add BetterMail/Sources/UI/ThreadCanvasView.swift
git commit -m "feat: add Action Items context menu to canvas thread nodes"
```

---

## Task 6: ActionItemsView

**Files:**
- Create: `BetterMail/Sources/UI/ActionItemsView.swift`

- [ ] **Step 1: Create the view**

```swift
// BetterMail/Sources/UI/ActionItemsView.swift
import SwiftUI

internal struct ActionItemsView: View {
    @ObservedObject internal var viewModel: ThreadCanvasViewModel
    @State private var showDone = false
    @State private var items: [ActionItem] = []

    internal var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            if items.isEmpty {
                emptyState
            } else {
                itemList
            }
        }
        .task {
            await loadItems()
        }
        .onChange(of: viewModel.actionItemIDs) { _, _ in
            Task { await loadItems() }
        }
    }

    // MARK: - Subviews

    private var topBar: some View {
        HStack(spacing: 8) {
            Text("⚡ Action Items")
                .font(.headline)
            Text(subtitleText)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Button(showDone ? "Hide done" : "Show done") {
                showDone.toggle()
            }
            .buttonStyle(.borderless)
            .font(.caption)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var subtitleText: String {
        let open = items.filter { !$0.isDone }.count
        let folderCount = Set(items.filter { !$0.isDone }.compactMap(\.folderID)).count
        if open == 0 { return "All done" }
        return "\(open) open · \(folderCount) folder\(folderCount == 1 ? "" : "s")"
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Text("No action items yet")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Right-click any thread on the canvas\nto add an action item.")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var itemList: some View {
        let grouped = groupedItems
        return List {
            ForEach(grouped, id: \.folderID) { group in
                Section {
                    ForEach(group.items) { item in
                        ActionItemRow(item: item,
                                      onToggleDone: { viewModel.toggleActionItemDone(item.id) })
                    }
                } header: {
                    HStack {
                        Text(group.folderTitle)
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(.secondary)
                            .textCase(nil)
                        Text("\(group.items.count)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.15), in: Capsule())
                        Spacer()
                    }
                }
            }
        }
        .listStyle(.inset)
    }

    // MARK: - Grouping

    private struct ItemGroup {
        let folderID: String?
        let folderTitle: String
        let items: [ActionItem]
    }

    private var groupedItems: [ItemGroup] {
        let visible = showDone ? items : items.filter { !$0.isDone }
        let folderMap = Dictionary(grouping: visible, by: \.folderID)
        let folders = viewModel.threadFolders

        var groups: [ItemGroup] = folderMap.compactMap { folderID, groupItems in
            guard let fid = folderID else { return nil }
            let title = folders.first(where: { $0.id == fid })?.title ?? fid
            return ItemGroup(folderID: fid,
                             folderTitle: title,
                             items: groupItems.sorted { $0.addedAt > $1.addedAt })
        }
        .sorted { $0.folderTitle < $1.folderTitle }

        if let unfiled = folderMap[nil], !unfiled.isEmpty {
            groups.append(ItemGroup(folderID: nil,
                                    folderTitle: "Unfiled",
                                    items: unfiled.sorted { $0.addedAt > $1.addedAt }))
        }
        return groups
    }

    // MARK: - Data

    private func loadItems() async {
        items = await MessageStore.shared.fetchActionItems()
    }
}

// MARK: - Row

private struct ActionItemRow: View {
    let item: ActionItem
    let onToggleDone: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Button(action: onToggleDone) {
                Image(systemName: item.isDone ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(item.isDone ? Color.green.opacity(0.7) : Color.secondary)
                    .font(.system(size: 16))
            }
            .buttonStyle(.borderless)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.subject.isEmpty ? "(no subject)" : item.subject)
                    .font(.callout)
                    .fontWeight(.medium)
                    .foregroundStyle(item.isDone ? .tertiary : .primary)
                    .strikethrough(item.isDone)
                    .lineLimit(1)
                Text("\(item.from) · \(item.date.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            if !item.tags.isEmpty {
                HStack(spacing: 4) {
                    ForEach(item.tags.prefix(3), id: \.self) { tag in
                        Text(tag)
                            .font(.system(size: 9, weight: .medium))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(item.isDone ? 0.08 : 0.15),
                                        in: RoundedRectangle(cornerRadius: 4))
                            .foregroundStyle(item.isDone ? .tertiary : .secondary)
                    }
                }
            }
        }
        .padding(.vertical, 2)
        .opacity(item.isDone ? 0.55 : 1)
    }
}
```

Note: `viewModel.threadFolders` is the confirmed `@Published` property name in `ThreadCanvasViewModel`. `ThreadFolder` has a `.title: String` field (confirmed in `Sources/Models/ThreadFolder.swift` line 98).

- [ ] **Step 2: Build check**

```bash
xcodebuild \
  -project BetterMail.xcodeproj \
  -scheme BetterMail \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  build > /tmp/xcodebuild.log 2>&1
grep -n "error:\|BUILD FAILED" /tmp/xcodebuild.log || echo "BUILD SUCCEEDED"
```

Fix any property name mismatches by checking the actual published vars in `ThreadCanvasViewModel`.

- [ ] **Step 3: Commit**

```bash
git add BetterMail/Sources/UI/ActionItemsView.swift
git commit -m "feat: add ActionItemsView with grouped flat list"
```

---

## Task 7: Wire up sidebar + default launch

**Files:**
- Modify: `BetterMail/Sources/UI/MailboxSidebarView.swift`
- Modify: `BetterMail/ContentView.swift`

- [ ] **Step 1: Add Action Items sidebar row**

In `MailboxSidebarView`, the `body` builds a `List`. Add the Action Items row at the very top, before the `allEmails` row:

```swift
// At the top of the List { ... } body, before sidebarRow(scope: .allEmails, ...)
sidebarRow(scope: .actionItems,
           title: NSLocalizedString("mailbox.sidebar.action_items",
                                    comment: "Action Items sidebar entry"),
           systemImage: "bolt.circle")
```

- [ ] **Step 2: Set default sidebar selection in ContentView**

`ContentView` creates `ThreadCanvasViewModel` with default `activeMailboxScope = .allEmails`. Change the ViewModel's initial value:

In `ThreadCanvasViewModel.swift`, find:

```swift
@Published internal private(set) var activeMailboxScope: MailboxScope = .allEmails
```

Change to:

```swift
@Published internal private(set) var activeMailboxScope: MailboxScope = .actionItems
```

- [ ] **Step 3: Wire `.actionItems` scope to show ActionItemsView**

`ContentView` currently always shows `ThreadListView` in the detail column. Update it to show `ActionItemsView` when the scope is `.actionItems`:

```swift
detail: {
    if viewModel.activeMailboxScope == .actionItems {
        ActionItemsView(viewModel: viewModel)
            .frame(minWidth: 480, minHeight: 400)
    } else {
        ThreadListView(viewModel: viewModel,
                       settings: settings,
                       inspectorSettings: inspectorSettings,
                       displaySettings: displaySettings)
            .frame(minWidth: 720, minHeight: 520)
    }
}
```

- [ ] **Step 4: Build check**

```bash
xcodebuild \
  -project BetterMail.xcodeproj \
  -scheme BetterMail \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  build > /tmp/xcodebuild.log 2>&1
grep -n "error:\|BUILD FAILED" /tmp/xcodebuild.log || echo "BUILD SUCCEEDED"
```

- [ ] **Step 5: Commit**

```bash
git add BetterMail/Sources/UI/MailboxSidebarView.swift \
        BetterMail/Sources/ViewModels/ThreadCanvasViewModel.swift \
        BetterMail/ContentView.swift
git commit -m "feat: add Action Items sidebar entry and set as default launch view"
```

---

## Task 8: Full test suite + final build

- [ ] **Step 1: Run all tests**

```bash
xcodebuild test \
  -project BetterMail.xcodeproj \
  -scheme BetterMail \
  -destination 'platform=macOS' \
  > /tmp/xcodebuild.log 2>&1
grep -n "error:\|TEST FAILED\|TEST SUCCEEDED\|BUILD FAILED" /tmp/xcodebuild.log | head -30
```

Expected: all existing tests pass, all 6 new ActionItemTests pass.

- [ ] **Step 2: Final build verification**

```bash
xcodebuild \
  -project BetterMail.xcodeproj \
  -scheme BetterMail \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  build > /tmp/xcodebuild.log 2>&1
grep -n "error:\|BUILD FAILED" /tmp/xcodebuild.log || echo "BUILD SUCCEEDED"
```

- [ ] **Step 3: Final commit**

```bash
git add -A
git commit -m "feat: Action Items — tag emails from canvas, view grouped by folder"
```
