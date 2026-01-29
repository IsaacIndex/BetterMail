## 1. Implementation
- [x] 1.1 Map current summary pipeline and identify data needed for per-email inputs (subject, body, prior thread context, manual attachments order).
- [x] 1.2 Extend summary input builder to produce per-node fingerprints keyed to email position and prior-content hash.
- [x] 1.3 Add per-email summary generation, caching, and regeneration triggers; display in inspector panel.
- [x] 1.4 Introduce folder-level summary aggregation (includes nested folders) with 30s debounce and cancel/overwrite semantics; render in folder header and inspector.
- [x] 1.5 Update persistence for new summary scopes and write migration (if needed) to avoid collisions with thread-level cache.
- [x] 1.6 Add tests covering per-node inputs, regeneration triggers, debounce cancellation, and UI state for node/folder summaries.
- [ ] 1.7 Run validation and lint/build checks (`openspec validate add-ai-node-folder-summaries --strict`, unit tests). (Unit tests failed: scheme not configured for test action.)
