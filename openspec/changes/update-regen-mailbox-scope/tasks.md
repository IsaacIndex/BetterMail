## 1. Implementation
- [x] 1.1 Derive the mailbox scope used by MessageStore (including “All Inboxes”) and inject/use it in Re-GenAI counting and regeneration calls.
- [x] 1.2 Add/adjust logging to record the effective mailbox scope for regeneration runs.
- [ ] 1.3 Validate with a manual run over a date range that contains messages in “All Inboxes” and confirm count > 0 and summaries regenerate.

## 2. Validation
- [x] 2.1 `xcodebuild -project BetterMail.xcodeproj -scheme BetterMail -configuration Debug -destination 'platform=macOS,arch=arm64' build`
