## 1. Implementation
- [ ] 1.1 Add Settings UI for Batch Backfill with date range pickers (default Jan 1 current year → today) and a start button.
- [ ] 1.2 Add view model state for backfill progress: total count, completed, current batch size, status message, error.
- [ ] 1.3 Implement backfill actor/service that:
  - counts total messages for selected mailbox and range
  - fetches messages in batches of 5; on batch failure, retries with smaller batches (<5) until resolved
  - reports progress updates to the UI layer
- [ ] 1.4 Wire status/progress bar to the view model; ensure UI updates happen on @MainActor while work runs off the main actor.
- [ ] 1.5 Add localization strings for the Settings backfill UI and statuses.
- [ ] 1.6 Validate UX and build via `xcodebuild -project BetterMail.xcodeproj -scheme BetterMail -configuration Debug -destination 'platform=macOS,arch=arm64' build`.
