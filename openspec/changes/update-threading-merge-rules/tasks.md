## 1. Implementation
- [x] 1.1 Add Core Data entities for manual thread groups and group-to-message/JWZ mappings, plus migration from existing overrides.
- [x] 1.2 Update threading post-processing to merge JWZ sets, track manual attachments, and rebuild thread membership.
- [x] 1.3 Revise selection grouping/ungrouping logic to follow the four merge cases.
- [x] 1.4 Update connector layout to render per-JWZ-subthread lanes with dynamic offsets.
- [x] 1.5 Add/update XCTest coverage for grouping rules and connector lane mapping.

## 2. Validation
- [ ] 2.1 Run threading-related tests. (failed: DerivedData permission error)
- [x] 2.2 Build the app with `xcodebuild -project BetterMail.xcodeproj -scheme BetterMail -configuration Debug -destination 'platform=macOS' build`.
