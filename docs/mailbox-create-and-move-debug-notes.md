# Mailbox Create-and-Move Debug Notes (March 6, 2026)

This page records all directions attempted in this session for Apple Mail mailbox creation and move behavior, especially for Outlook-backed accounts (for example `Isaac IBM`).

## Symptoms observed
- `Create-and-move failed` with AppleScript runtime errors `-10000` (`AppleEvent handler failed`).
- Intermittent `-1728` mailbox resolution failures (destination mailbox not found).
- Parser failure `-2741` (`Expected class name but found identifier`).
- Outlook account sometimes showed only `Inbox` in sidebar.
- Creating child mailbox under parent sometimes produced literal names like `Important/HKJC` as one mailbox token, or duplicated parent (`Important/Important/HKJC`).

## Directions attempted
1. Account-root creation by assigning `name` directly to `mailboxPath` (for example `Important/HKJC`).
2. Parent-container creation using `make new mailbox at mailbox "Parent" ...` with leaf name.
3. Normalize create inputs to strip duplicated parent prefixes before script generation.
4. Return script-created mailbox name/path and avoid naive `parent + "/" + name` concatenation when possible.
5. Extend mailbox path resolution with multi-pass matching:
   - literal full-name match (provider exposes slash in name),
   - hierarchical segment walk,
   - full computed path match,
   - leaf fallback.
6. Rework mailbox hierarchy fetch to use mailbox `container` chain and emit `{account, path, name, parentPath}` rows.
7. Add account name/id fallback handling when account name metadata is unstable.
8. Replace `mailbox of ...` parent traversal with `container of ...` where relevant.
9. Diagnose `-2741` parser failures:
   - avoid app terms in handlers unless wrapped in `tell application id "com.apple.mail"`,
   - remove fragile class-literal checks and use container-probe logic instead.
10. Update tests around generated AppleScript snippets for resolver behavior.
11. Disable name-based root-folder pruning in `MailboxHierarchyBuilder` because it can hide valid mailboxes when root and child names overlap.
12. Replace recursive hierarchy construction with conservative per-account mailbox enumeration:
   - enumerate all mailboxes from account scope (`every mailbox` with `mailboxes` fallback),
   - derive path/parent via container-chain walk,
   - prioritize completeness (show all folders) over perfect provider-specific nesting.

## Temporary product decision
- Create-and-move UI path is temporarily hidden in the mailbox move sheet.
- Move-to-existing-folder remains available.

## Next return point
- Re-enable create-and-move only after a provider-specific create strategy is validated against:
  - Outlook account (literal slash-name behavior),
  - parent-child nested mailbox behavior,
  - sidebar hierarchy rendering consistency after refresh.

## Follow-up guardrails (PR #25 review fixes)
- MessageStore folder filters now match `mailboxID` by exact full path only for scoped fetch/count queries, preventing sibling folders that share the same leaf name from being co-mingled (for example `Projects/Acme` vs `Clients/Acme`).
- MailAppleScript mailbox resolution now attempts hierarchy/full-path resolution before leaf-name fallback, so duplicate leaf names under different parents resolve to the requested path first.
