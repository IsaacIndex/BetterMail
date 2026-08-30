# Visual Email Organizer Dirty-Worktree Baseline

Captured before organizer behavior changes on 2026-08-24.

The following pre-existing working-tree changes are outside the organizer implementation and must be preserved:

- `BetterMail/Resources/Localizable.strings`
- `BetterMail/Sources/Services/GraphAutomationCoordinator.swift`
- `BetterMail/Sources/UI/AccessibilityIdentifiers.swift`
- `BetterMail/Sources/UI/Graph/GraphAutomationQueueSheet.swift`
- `TechDocs/index.md`
- `Tests/GraphAutomationTests.swift`
- `graphify-out/.graphify_learning.json`
- `graphify-out/reflections/LESSONS.md`
- `graphify-out/memory/query_20260823_165419_review_the_entire_report_and_suggest_directions_or.md`
- `graphify-out/memory/query_20260823_172906_yes_help_me_make_the_7_suggested_changes__as_well.md`

The first six files implement and document the existing queue-wide Graph Automation **Approve All** work. Organizer changes must retain that behavior, including its test coverage, while later defining duplicate-source conflicts explicitly rather than silently skipping or counting them as approved.

The approved OpenSpec change under `openspec/changes/add-visual-email-organizer/` is the contract for this work and is not part of the unrelated dirty boundary.

Validation and delivery records must distinguish this baseline from organizer-authored changes. No reset, checkout, stash, or unrelated cleanup is authorized by the organizer work.
