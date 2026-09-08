# Apple Mail mutation inventory

This is the maintained production call-site inventory for the organization
safety contract. It distinguishes BetterMail-only changes from physical Apple
Mail mutations and records the boundary that each path must cross.

## Effect and entry-point matrix

| Path | Visible effect | Production entry point | Enforced boundary |
| --- | --- | --- | --- |
| Manual Group add/create/remove | BetterMail only | `ThreadCanvasViewModel.organizeThreads` and `createOrganizerGroup` | `OrganizationCommandService` writes the prepared ledger record and applies one serialized `OrganizationMutationStore` delta. No Mail authorization exists. |
| Rail, graph, keyboard, menu, or VoiceOver Group placement | BetterMail only | `OrganizerWorkspaceView`, `GraphCanvasView`, and `ObsidianGraphScene` delegate to the same ViewModel commands | Gesture and accessibility callbacks carry intent only. They cannot call a Mail transport. |
| Graph suggestion review and acceptance | BetterMail only unless a separately disclosed mapped-Mail phase is approved | `GraphSuggestionReviewSheet`, inline organizer cards, and `GraphAutomationCoordinator` | Review state and membership remain local. Any mapped Mail phase is a later `OrganizationMailExecutionService` request. |
| Graph Archive and restore | BetterMail only | `GraphCanvasViewModel.archiveThread` and the archive branch of `restore` | `MessageStore` archive state plus the unified History adapter; no Mail request is constructed. |
| Spatial layout and Reset Layout | BetterMail only | `GraphCanvasViewModel` and `GraphSpatialStateStore` | Opaque scoped layout storage only; no Mail request is constructed. |
| Snip | Changes Apple Mail | `GraphCanvasViewModel.confirmSnipBatch` -> `executeSnipItem` | Foreground disclosure creates `OrganizationMailAuthorization`, then `OrganizationMailExecutionService.move` -> `OrganizationMailGateway.move`. |
| Snip restore | Changes Apple Mail | `GraphCanvasViewModel.restore` -> `restoreMovedMessages` | A fresh foreground restore authorization and an operation ID bound to the exact residual route set precede `OrganizationMailExecutionService.restore`. |
| Explicit selection Move | Changes Apple Mail | `ThreadCanvasViewModel.moveSelectionToMailboxFolder` | Exact current routes and foreground authorization precede `OrganizationMailExecutionService.move`. |
| Create mailbox and move selection | Changes Apple Mail; mailbox creation can be irreversible | `ThreadCanvasViewModel.createMailboxFolderAndMoveSelection` | Two separately authorized ledger operations: `createMailbox`, followed only after its receipt by exact-route `move`. The production sheet remains disabled until it can present both confirmations. |
| Move a thread into a Group with a mapped Mailbox Folder | Mixed | `ThreadCanvasViewModel.moveThread` -> `moveThreadToAssignedFolderMailbox` | BetterMail membership commits first. The optional Mail phase requires current `messageMove` consent and passes through the execution service/gateway; without it, Mail is untouched and the local Group remains. |
| Automatic mailbox-thread rule | Changes Apple Mail | `ThreadCanvasViewModel` automatic mailbox-thread pass | Absent, legacy, unknown, disabled, or revoked consent stops before ledger preparation. Current `messageMove` consent plus exact routes is required by the common service/gateway. |
| Graph Automation evaluation or app-only approval | BetterMail only | `GraphAutomationCoordinator.evaluateNow`, `approve`, and `approveAll` | Recommendation, mode, mapping, and queue refresh cannot manufacture Mail authorization. |
| Graph Automation mapped move or retry | Mixed | `GraphAutomationCoordinator.executeMailboxPhase` | Current `messageMove` consent and exact disclosure precede `OrganizationMailExecutionService.move`. Each deliberate attempt has a distinct operation ID. |
| Graph Automation compensation, recovery, or undo restore | Changes Apple Mail | `GraphAutomationCoordinator.finishMailRestore` and `restoreMovedMessages` | Separate current `messageRestore` consent is required. Only a known residual set may be retried; unknown outcomes remain manual recovery and are not replayed. |

## Sole low-level transport exception

`DefaultOrganizationMailGatewayTransport` in
`BetterMail/Sources/Organizer/OrganizationMailGateway.swift` is the only
production source allowed to call:

- `MailControl.createMailbox`;
- `GraphSnipMailMoving.moveMessages`, implemented by
  `MailAppleScriptClient.moveMessages`.

The legacy `MailControl.moveMessagesByInternalID` and
`MailControl.moveSelection` endpoints remain compiled for non-organizer Mail
features and tests, but no production organization caller invokes them. A
source-tree invariant test fails if one of the ViewModels, coordinators, or UI
surfaces reintroduces a raw call.

## Authorization and replay invariants

1. Every Mail request discloses mutation type, exact count, exact source routes
   where applicable, destination, and reversibility.
2. Foreground actions require a matching user-confirmation authorization.
   Automatic actions require a matching authorization issued from the current
   consent schema and the same still-current consent at execution time.
3. Rejected authorization produces zero transport calls and zero prepared
   ledger rows. Revocation blocks prepared-but-not-started work.
4. The gateway advances the ledger to `mailApplying` before the external call
   and records complete, partial, or recovery receipts afterward.
5. A completed operation can replay only its receipt and never repeats Mail.
   A partial or recovery operation cannot replay its original manifest. A
   deliberate residual attempt gets a new ID derived from the exact residual
   routes.
6. Relaunch converts an interrupted `mailApplying` operation to a non-retryable
   recovery record because BetterMail cannot know whether Apple Mail completed.
7. Exact recovery manifests are encrypted locally. Public logs, telemetry,
   metrics, suggestions, and shareable evidence contain counts/statuses only.

## Regression evidence

`OrganizationMailGatewayTests` supplies a transport spy and covers every
`OrganizationOperationKind` across mailbox creation, move, and restore with no
authorization; all combinations must produce zero calls and no ledger rows.
The suite also covers absent/legacy/malformed/unknown/disabled/revoked consent,
changed disclosure, exact-route validation, mailbox creation, encrypted
manifests, partial receipts, missing keys, completed replay, and rejection of
partial/unknown replay. `GraphAutomationTests` proves the formerly unsafe
automatic mapped-Mail path makes no call without separate current consent and
that unknown outcomes never auto-retry. `GraphTests` covers exact Snip and
residual restore behavior through the same production service boundary.
