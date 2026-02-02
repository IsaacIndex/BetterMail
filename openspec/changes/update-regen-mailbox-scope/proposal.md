# Change: Align Re-GenAI mailbox scope with stored messages

## Why
- Re-GenAI currently hardcodes the mailbox to `inbox`, while stored messages are tagged `All Inboxes`, causing counts to return 0 and regeneration to never run.

## What Changes
- Use the same mailbox scope that MessageStore uses for cached messages (including the aggregated “All Inboxes”) when counting and running summary regeneration from Settings.
- Keep logging in place to confirm the effective mailbox scope at runtime.

## Impact
- Affected specs: `apple-intelligence-summaries`
- Affected code: `BatchBackfillSettingsViewModel`, `SummaryRegenerationService`, `MessageStore` mailbox filtering
