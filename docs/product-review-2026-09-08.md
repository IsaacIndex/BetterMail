# BetterMail product review — 2026-09-08

BetterMail's three canvas modes, Group organization, and local Apple Mail integration are already substantial. This pass concentrates on making the Action Items workflow dependable and easier to use. It reviews source and tests for the main shell, list and inspector, cache access, selection, and build configuration. It is not a release-readiness audit of every subsystem.

## Applied improvements

| Finding | Result |
| --- | --- |
| Storage identifies action items by account plus message ID, but rows previously selected a bare message ID. | Native list tags and selection now use the scoped action-item ID. Rows show their account. The inspector resolves the saved account from the local cache. |
| The inspector previously searched only the canvas roots, which are date-windowed. An older task could be listed without an inspectable email. | A targeted cache lookup loads the selected source independently of the canvas window. It preserves source-absence and calendar-response suppression. |
| Older records without an account can match several accounts. | An explicit unavailable state explains ambiguity; the app does not choose an account. A missing cache row also produces a visible explanation without deleting the task. |
| Completion filtering could leave an empty list after the last open task was checked. | Separate first-use, all-complete, and no-match states offer View All Emails, Show done, or Clear search as appropriate. |
| A deleted Group's identifier could appear as a section heading. | Such tasks appear under Unfiled. Open Group counts include only Groups that still exist. |
| Action Items lacked search. | A local search field matches subjects, senders, accounts, saved tags, and current Group names without regard to case or diacritics. Show done continues to govern completed-task visibility. |

Selection requests carry a revision as well as an account-scoped item ID. Cancellation or a later request prevents an earlier fetch from replacing the inspector. Reselecting the same row can retry a failed load. Filtering out or removing a selected task clears the inspector. Existing generated summaries remain available when the loaded canvas supplies one unambiguous source; ambiguous bare summary keys are not reused for these task rows.

## Recommended next work

1. **Surface failed task saves and reads.** `MessageStore` still wraps existing action-item CRUD in `try?`, and failed list reads become an empty array. Add a throwing storage interface and an inline retry state that retains the last successful list. This is supported by source inspection; a disk-failure scenario was not reproduced in this pass.
2. **Audit account identity through the rest of the canvas and summary cache.** `ThreadNode.id` and several selection/summary APIs still use bare message IDs. The Action Items fix is deliberately local. A global change needs a migration plan and separate tests for manual joins, Group membership, cached summaries, and duplicate RFC Message-IDs across accounts.
3. **Make the build setup portable and document the actual requirements.** The project pins `macosx26.2`, while the selected Xcode here provides `macosx26.5`. The README also advertises older system/Xcode requirements than the project's macOS 26 deployment target. Reconcile this with the intended supported release environment before changing SDK policy. Signing prerequisites remain a separate machine setup concern.
4. **Resolve the synthetic harness's toolbar overlap before wider visual acceptance.** Its window showed a blank toolbar/material area covering part of the detail header in both Action Items and the existing Default view, at two window sizes. The cause and whether production windows share it were not established. This limits the visual evidence below.

## Validation

- Initial normal build stopped before compilation because `macosx26.2` is unavailable. Full log: `/tmp/bettermail-product-review.hfRj2o/baseline-build.log`.
- The first isolated Action Items run compiled the app and passed 21 tests using the installed SDK, with signing disabled only for temporary test products. Full log: `/tmp/bettermail-product-review.hfRj2o/action-items-tests.log`.
- Final regression run: **87 tests passed, 0 failures**, including 22 Action Items tests plus mailbox navigation, inspector, calendar recovery, and graph integration. Full log: `/tmp/bettermail-product-review.hfRj2o/final-verification.log`; result bundle: `/tmp/bettermail-product-review.hfRj2o/final-verification.xcresult`.
- Final macOS source build succeeded with `-sdk macosx`, `CODE_SIGNING_ALLOWED=NO`, and `SWIFT_ACTIVE_COMPILATION_CONDITIONS='DEBUG BETTERMAIL_DISABLE_PREVIEWS'`. These are command-line overrides for temporary validation products. Full log: `/tmp/bettermail-product-review.hfRj2o/final-build.log`. This does not establish a signed install or release build.
- The isolated diagnostic app launched from `/tmp` using `synthetic-action-items-review-20260908`. Its banner showed **Apple Mail locked, External Mail calls: 0**. Accessibility and screenshots confirmed the initial empty state and search field; typing exposed Clear search, and Escape cleared the query. A complete populated-list/inspector/completion UI round trip was not performed. This smoke check preceded the final internal selection/summary-lookup refinements; the final code was rebuilt and the regressions rerun afterward.
- `git diff --check`, localization plist syntax validation, and exact preservation checks passed. Existing graph source/test patches remained byte-identical, and original README/TechDocs content was retained. Evidence: `/tmp/bettermail-product-review.hfRj2o/preservation-checks.json`.
- The guarded install preflight stopped because the ignored local app config lacks the required `BETTERMAIL_SIGNING_IDENTITY_SHA1`. Full log: `/tmp/bettermail-product-review.hfRj2o/install-preflight.log`. Project signing, entitlements, bundle identifiers, and minimum OS versions were not changed.
- Existing graph-dragging source/tests and documentation changes were preserved. No real email was moved, sent, or deleted during validation.

## Implementation references

- `BetterMail/Sources/UI/ActionItemsView.swift`: search, native list selection, inspector and empty states.
- `BetterMail/Sources/Models/ActionItemListProjection.swift`: shared filtering, grouping, counts, and empty-state decisions.
- `BetterMail/Sources/Models/ActionItem.swift`: scoped identity and source-resolution error.
- `BetterMail/Sources/Models/ActionItemSummaryLookup.swift`: a single traversal of loaded roots supplies unambiguous summary matches for all task rows.
- `BetterMail/Sources/Storage/MessageStore.swift`: selected-source cache lookup.
- `BetterMail/Sources/ViewModels/ThreadCanvasViewModel.swift`: scoped selection lifecycle.
- `Tests/ActionItemTests.swift`: in-memory regression coverage.

The selection-keyed view task follows Apple's [asynchronous SwiftUI work guidance](https://developer.apple.com/tutorials/instruments/executing-work-asynchronously); cache work itself runs through Core Data's existing background-context API.
