## 1. Implementation
- [x] 1.1 Add mailbox hierarchy domain models and AppleScript data-source helpers to enumerate accounts and nested mailbox folders from Apple Mail.
- [x] 1.2 Add mailbox scope state to `ThreadCanvasViewModel` with default `All Inboxes`, and wire scoped refresh/rethread fetch behavior.
- [x] 1.3 Add mailbox sidebar UI showing accounts and expandable subfolder tree, with selection updating active mailbox scope.
- [x] 1.4 Add mailbox-folder action controls for selected nodes: choose existing mailbox folder destination and execute move using selected node message IDs.
- [x] 1.5 Add "new mailbox folder" flow that requires account + optional parent folder, creates the folder in Apple Mail, then moves selected nodes to it.
- [x] 1.6 Keep existing thread-folder actions intact and disambiguate user-facing labels/text between thread folders and mailbox folders.
- [x] 1.7 Refresh mailbox hierarchy and scoped canvas data after successful mailbox folder create/move operations.

## 2. Validation
- [x] 2.1 Add/update unit tests for mailbox hierarchy parsing, scope selection behavior, and move/create action guards (including mixed-account selection handling).
- [x] 2.2 Add/update unit tests for MailControl mailbox-folder move/create command generation and path/account resolution.
- [x] 2.3 Build app and capture full output in `/tmp/xcodebuild.log` using project-required command sequence (`xcrun simctl erase all`, then `xcodebuild ... > /tmp/xcodebuild.log 2>&1`), triaging any compilation errors.

## 3. Documentation
- [x] 3.1 Update `/Users/isaacibm/GitHub/better-email-client/BetterMail/README.md` and relevant docs to describe mailbox sidebar navigation, mailbox-folder actions, and terminology distinctions.
