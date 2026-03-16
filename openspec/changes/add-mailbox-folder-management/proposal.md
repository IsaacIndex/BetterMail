# Change: Add mailbox account/folder navigation and mailbox-folder move actions

## Why
BetterMail currently centers the experience on the aggregate "All Inboxes" canvas and internal thread-folder grouping. Users cannot browse Apple Mail accounts/subfolders in-app or move selected messages to existing/new Apple Mail folders from BetterMail.

## What Changes
- Add account-aware mailbox hierarchy support (accounts + nested mailbox folders) sourced from Apple Mail.
- Keep **All Inboxes** as the default scope on launch.
- Add a mailbox sidebar that shows account folders and subfolders from Apple Mail, with expand/collapse and selection.
- Add a mailbox-folder move action for selected canvas nodes that targets Apple Mail folders (existing or newly created).
- Allow creating a new Apple Mail folder during move flow by choosing account + parent folder.
- Explicitly distinguish terminology in UI/flows:
  - **Thread Folder** = existing BetterMail canvas grouping feature.
  - **Mailbox Folder** = real Apple Mail folder/account hierarchy.

## Impact
- Affected specs:
  - `mailbox-navigation` (new)
  - `mailbox-folder-actions` (new)
- Affected code (expected):
  - `/Users/isaacibm/GitHub/better-email-client/BetterMail/BetterMail/ContentView.swift`
  - `/Users/isaacibm/GitHub/better-email-client/BetterMail/BetterMail/Sources/UI/ThreadListView.swift`
  - `/Users/isaacibm/GitHub/better-email-client/BetterMail/BetterMail/Sources/ViewModels/ThreadCanvasViewModel.swift`
  - `/Users/isaacibm/GitHub/better-email-client/BetterMail/BetterMail/Sources/DataSource/MailAppleScriptClient.swift`
  - `/Users/isaacibm/GitHub/better-email-client/BetterMail/BetterMail/MailControl.swift`
  - `/Users/isaacibm/GitHub/better-email-client/BetterMail/BetterMail/Sources/Storage/MessageStore.swift`
  - `/Users/isaacibm/GitHub/better-email-client/BetterMail/BetterMail/Resources/Localizable.strings`
