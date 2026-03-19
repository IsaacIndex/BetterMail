# Action Items Feature — Design Spec

**Date:** 2026-03-19
**Status:** Approved

---

## Overview

Add an **Action Items** view to BetterMail that lets users tag any email thread card as an action item via right-click and review all tagged items in a dedicated, default-on-launch sidebar view. Tagged items are displayed as a flat list grouped by canvas folder, with the email's existing 3 tags carried over automatically.

---

## Goals

- Let users surface emails that require follow-up without leaving BetterMail
- Make Action Items the first thing visible when the app launches
- Keep the UX email-native: no manual task creation, no due dates, no extra metadata

## Non-Goals

- Due dates, priority levels, or reminders (out of scope for v1)
- Creating action items from outside the canvas (e.g., from the inspector or sidebar)
- Syncing action items to external task managers

---

## Architecture

### Data Model

A new persistent store for action item records, backed by Core Data via `MessageStore`.

```
ActionItem
  - id: String            // matches EmailMessage.messageID
  - threadID: String      // JWZ thread ID
  - addedAt: Date
  - isDone: Bool
  - folderID: String?     // canvas folder ID the thread belongs to at tag time
```

`ActionItem` records are lightweight — they reference existing `EmailMessage` data and do not duplicate it.

### Tag Persistence

Action item state is stored in Core Data alongside messages. `MessageStore` gains two methods:

```swift
func addActionItem(for message: EmailMessage, folderID: String?)
func removeActionItem(for message: EmailMessage)
func toggleActionItemDone(_ itemID: String)
func fetchActionItems() -> [ActionItem]
```

### Tag Source — Tags Carried Over

Each `EmailMessage` already carries up to 3 display tags (rendered as chips on canvas cards via `EmailTagProvider`). When a thread is tagged as an action item, those same 3 tag values are snapshotted and stored on the `ActionItem` record so the Action Items list always shows the tags as they appeared at tag time.

---

## UI Components

### 1. Context Menu on Thread Canvas Node

**Trigger:** Right-click on any `ThreadCanvasNode`

**New menu item:** `⚡ Add to Action Items` (or `✓ Remove from Action Items` if already tagged), placed at the top of the context menu above the separator.

**Location:** `ThreadCanvasView.swift` — the existing context menu on canvas nodes gains this item. The `ThreadCanvasViewModel` handles the action dispatch.

### 2. Sidebar Entry

A new top-level entry in `MailboxSidebarView`:

```
⚡ Action Items
```

Positioned above "All Emails" — making it the first entry and the default selection on launch.

**Default on launch:** `ContentView` sets the initial sidebar selection to `.actionItems`. If a user navigates away, the selection persists normally via `NavigationSplitView`.

### 3. Action Items View

Replaces the right panel content when `.actionItems` is selected in the sidebar. A new `ActionItemsView` SwiftUI view.

**Layout:**

```
┌─ Top bar ─────────────────────────────────────────────┐
│ ⚡ Action Items   4 open · 2 folders      [Show done] │
├───────────────────────────────────────────────────────┤
│ 🗂 HKJC - B&V                              3 items    │
│   ○  RE: [EXT] DBC JKC/TNC Leaderboard   TAG TAG TAG │
│      Len Wong · Mar 18                                │
│   ○  CR086 ITD Configurable Wagering      TAG TAG TAG │
│      Getter K H · Mar 10                              │
│   ✓  Spring CRs — SAT walkthrough (done) TAG TAG TAG │
├───────────────────────────────────────────────────────┤
│ ☁ AWS Migration                            2 items    │
│   ○  IBM Azure to AWS — price book review TAG TAG TAG │
│      Theo · Mar 11                                    │
│   ○  Cloud Team — DockerFiles + helm      TAG TAG TAG │
│      Hinchi · Mar 8                                   │
└───────────────────────────────────────────────────────┘
```

**Row elements (left to right):**
- Completion circle (tap to toggle done)
- Subject (truncated, strikethrough when done)
- Sender · Date (secondary line)
- Up to 3 tag chips (as snapshotted at tag time, dimmed when done)

**Grouping:** Items grouped by `folderID`. Threads not in any canvas folder appear under an "Unfiled" group at the bottom.

**"Show done" toggle:** Hidden by default; reveals completed items in-line within their group, greyed out and struck through.

**Empty state:** When no action items exist, show a centered message: *"Right-click any thread on the canvas to add an action item."*

---

## Settings & Launch Behavior

- `ContentView` initializes sidebar selection to `.actionItems` (new `MailboxSelection` case)
- No new user-facing setting needed — Action Items is always the default view
- The existing `MailboxSidebarExpansionSettings` is unaffected

---

## Testing

Test naming follows `test_<Method>_<Condition>_<ExpectedResult>()`.

| Test | Description |
|------|-------------|
| `test_addActionItem_newMessage_persistsRecord` | Adding an action item creates a Core Data record |
| `test_addActionItem_duplicateMessage_noopOrIdempotent` | Adding the same message twice does not create duplicates |
| `test_toggleActionItemDone_existingItem_flipsFlag` | Done toggle flips `isDone` and persists |
| `test_fetchActionItems_groupedByFolder_correctGroups` | Items are returned grouped by folderID |
| `test_removeActionItem_existingItem_deletesRecord` | Removing an action item deletes the Core Data record |
| `test_actionItemTags_snapshotAtTagTime_survivesMessageUpdate` | Tags are snapshotted, not live-linked |

All tests use in-memory Core Data stores. No network calls.

---

## File Changes

| File | Change |
|------|--------|
| `Sources/Storage/MessageStore.swift` | Add `ActionItem` entity and CRUD methods |
| `Sources/Models/ActionItem.swift` | New model struct |
| `Sources/UI/ActionItemsView.swift` | New view |
| `Sources/UI/ThreadCanvasView.swift` | Add context menu item |
| `Sources/ViewModels/ThreadCanvasViewModel.swift` | Handle `addActionItem` / `removeActionItem` actions |
| `Sources/UI/MailboxSidebarView.swift` | Add Action Items entry, set as default |
| `ContentView.swift` | Set default sidebar selection to `.actionItems` |
| `BetterMailTests/ActionItemTests.swift` | New test class |
