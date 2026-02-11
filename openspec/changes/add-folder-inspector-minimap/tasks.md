## 1. Implementation
- [x] 1.1 Add a dedicated non-scrollable minimap section to folder details inspector layout, with editable fields remaining in a separate scrollable section.
- [x] 1.2 Implement a folder minimap view that renders only node circles and connector lines from folder-scoped node structure.
- [x] 1.3 Add minimap interaction handling to resolve click locations into folder-scoped canvas jump targets (coordinate mapping first, nearest-node fallback).
- [x] 1.4 Reuse/extend existing folder jump orchestration so minimap jumps support incremental range expansion for off-screen target days.
- [x] 1.5 Add accessibility labels/tooltips for minimap interactive surface and ensure keyboard activation for navigation actions.

## 2. Validation
- [x] 2.1 Add/extend view-model tests for folder-scoped minimap jump target resolution, including nearest-node fallback and out-of-range expansion behavior. (Depends on 1.3, 1.4)
- [x] 2.2 Add/extend UI tests (or snapshot-level checks) for inspector layout split: minimap remains visible while details section scrolls. (Depends on 1.1, 1.2)
- [x] 2.3 Build the app and capture full logs in `/tmp/xcodebuild.log` using project command sequence (`xcrun simctl erase all` then `xcodebuild ... > /tmp/xcodebuild.log 2>&1`), then triage errors if present.

## 3. Delivery Notes
- [x] 3.1 Update relevant docs/spec references if implementation introduces new minimap-specific user-visible behavior details.
