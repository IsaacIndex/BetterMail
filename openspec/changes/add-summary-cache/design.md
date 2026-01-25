## Context
Apple Intelligence summaries are generated per thread root inside `ThreadCanvasViewModel` using the subject list of the root node. Results live only in memory, so every launch or rethread forces a fresh model call. That wastes startup time, makes summaries disappear when Apple Intelligence is unavailable, and duplicates work when threads are unchanged. Core Data currently stores messages, threads, manual groups, and folders but no summary cache.

## Goals / Non-Goals
- Goals: persist the latest Apple Intelligence summary per thread root; reuse it when inputs are unchanged; invalidate when thread membership/subjects change; keep UI aware of cache freshness; avoid blocking the main actor.
- Non-Goals: multi-version history of summaries, cross-device sync, or manual cache management UI.

## Decisions
- Add a new Core Data entity `ThreadSummaryEntity` with attributes: `threadID` (indexed string, primary key), `summaryText` (string), `generatedAt` (date), `fingerprint` (string hash of normalized subject list + message count), and `provider` (string, e.g., "foundation-models").
- Fingerprint algorithm: join up to 25 normalized subjects (trimmed, deduped, in descending date order) plus message count and manual group key; SHA256 to a hex string. This keeps reuse deterministic and small.
- Persistence API: MessageStore exposes async `upsertSummaries`, `fetchSummaries(for:)`, and `deleteSummaries(for:)` operating on thread IDs to support bulk rethread updates and cleanup when threads vanish.
- Summary pipeline changes: during `refreshSummaries`, compute fingerprints and first look for cached entries; if a cache matches, hydrate `threadSummaries` with cached text/status and skip generation. If missing or mismatched, enqueue generation and overwrite the cache on success. Stale caches are removed when roots disappear or threads are regrouped.
- Status handling: when provider is unavailable, show the last cached summary with a status like "Last updated HH:MM; Apple Intelligence unavailable"; no new generation is attempted until availability returns.

## Risks / Trade-offs
- Hash collisions are unlikely but possible; acceptable for cache reuse because stale summary is still benign. If correctness issues appear, include message IDs in the fingerprint later.
- Adding a new entity changes the store schema; automatic lightweight migration should handle the additive change, but we need a migration guard to avoid repeated work during startup.

## Migration Plan
- Extend `makeModel` to include `ThreadSummaryEntity`. Core Data's automatic migration covers the additive entity. No data backfill needed; cache populates on first generation.
- On load, delete cached summaries whose thread IDs are no longer present after rethreading to prevent orphan rows.

## Open Questions
- Should we cap cache age (e.g., 24 hours) even if fingerprint matches? Current plan reuses indefinitely; can add TTL later if needed.
- Should cache store the full subject list for audit/debug? Currently only the hash is stored to minimize footprint.
