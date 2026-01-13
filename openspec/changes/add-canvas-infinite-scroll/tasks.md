## 1. Implementation
- [ ] 1.1 Add view-model paging state for the canvas day window and expose visible day range tracking.
- [ ] 1.2 Update canvas layout to use a dynamic day count and compute empty day bands for the visible range.
- [ ] 1.3 Add a toolbar backfill action and status handling scoped to visible empty bands.
- [ ] 1.4 Extend AppleScript fetch support to request a date range and wire it to the backfill action.
- [ ] 1.5 Ensure cache-only paging uses Core Data fetches and rethreading is triggered only when new messages arrive.

## 2. Validation
- [ ] 2.1 Add/adjust unit tests for visible-range calculations and paging boundaries (if test infrastructure is present).
- [ ] 2.2 Build the app: `xcodebuild -project BetterMail.xcodeproj -scheme BetterMail -configuration Debug -destination 'platform=macOS' build`
