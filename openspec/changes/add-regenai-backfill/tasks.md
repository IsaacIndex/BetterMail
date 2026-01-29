## Implementation Tasks

- [ ] Wire a second Settings action labeled “Start Re-GenAI” beside the existing backfill button, reusing the date range pickers and disabling while running.
- [ ] Extend `BatchBackfillSettingsViewModel` (or sibling view model) with a regeneration flow that counts eligible messages in range, runs batch regeneration, and reports status/progress/errors.
- [ ] Implement a `SummaryRegenerationService` (or equivalent) that iterates messages in the date range, regenerates per-email summaries unconditionally, and batches folder summary refreshes.
- [ ] Update localization strings for new labels/status text.
- [ ] Ensure UI accessibility/VoiceOver labels reflect the new action and progress.
- [ ] Add tests covering regeneration batching and status mapping (unit for service, snapshot or logic tests for view model).
- [ ] Run `openspec validate add-regenai-backfill --strict` and ensure it passes.
