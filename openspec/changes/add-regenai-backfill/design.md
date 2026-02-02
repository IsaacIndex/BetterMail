# Design

## Context
Settings currently exposes a Batch Backfill that counts messages then fetches them in batches via `BatchBackfillService`, reporting progress and status. Apple Intelligence summaries are generated per-email node and rolled up to folders; regeneration occurs reactively (staleness, upstream changes) but there is no bulk re-run over a date range.

## Approach
1) **New command surface**: Add a sibling action to the existing Start Backfill button: “Start Re-GenAI”. It uses the same date pickers and mailbox context.
2) **Processing flow**: Reuse `BatchBackfillSettingsViewModel` to orchestrate either backfill or regeneration. Introduce a regeneration path that enumerates messages in the date range (no store mutation) and invokes the summary pipeline to regenerate per-email summaries, then triggers folder summary refreshes for any touched folders.
3) **Batching & progress**: Mirror backfill progress UX: counting first, then batches. Count step tallies eligible messages for summarization. Progress should report completed/total and current batch size. Errors should surface in-status and allow retry without killing partial progress.
4) **Concurrency & responsiveness**: Run regeneration off the main actor. UI updates stay on the main actor. Avoid re-fetching message bodies if already cached; rely on stored content to build summary inputs.
5) **Folder summaries**: After regenerating a batch of email summaries, enqueue refresh for their containing folders (and parents) with existing debounce rules. Progress need only reflect email-level regeneration, not folder rollups.
6) **Extensibility**: Keep the regeneration logic modular (e.g., `SummaryRegenerationService`) so other triggers (future CLI or auto-refresh) can reuse it.

## Open Questions
- Should regeneration skip nodes whose fingerprints already match the current model version? (User chose “regenerate all in range” → proceed unconditionally.)
- Is mailbox always “inbox” or should we respect currently selected mailbox from settings? (Backfill uses hardcoded inbox today; consider aligning but keep scope minimal unless blocking.)

## Risks / Mitigations
- **Throughput**: Summarization is slower than fetch; use batches and allow cancellation. Mitigate with conservative batch size (reuse 5) and progress visibility.
- **Folder churn**: Triggering folder rollups per batch could spam the debounce; batch updates to a set of folders before requesting refresh.
- **AI availability**: If Apple Intelligence unavailable, fail fast with a clear error and no partial state changes.
