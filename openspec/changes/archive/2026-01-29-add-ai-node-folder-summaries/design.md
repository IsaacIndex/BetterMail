## Context
Current Apple Intelligence support summarizes threads at the root level using only subject lines. There is no per-message digest, folder-level rollup, or body/context-aware comparison. Caching is keyed to thread roots; summaries live in `ThreadCanvasViewModel` and Core Data. Folder UI already has headers and an inspector, but no summary content.

## Goals / Non-Goals
- Goals: per-email summaries that highlight new info vs prior emails; folder summaries derived from member email summaries; debounced refresh with cancel/overwrite; persistence keyed to scope; UI placement per guidance (node inspector, folder header + inspector).
- Non-Goals: changing Mail ingestion, altering JWZ threading rules, adding third-party models.

## Decisions
- Scope keys: per-email summaries keyed by node ID plus prior-context hash to avoid recomputing unchanged nodes; folder summaries keyed by folder ID and include nested membership hash.
- Inputs: node summary prompt will include subject, body snippet/full text (bounded), and a concise digest of prior emails (including manually attached) to highlight deltas.
- Scheduling: folder summaries refresh on membership/content changes with a 30s debounce; new trigger cancels in-flight generation for that folder.
- Storage: add distinct cache records for node and folder scopes to avoid clashing with existing thread-root cache; reuse provider factory and availability messaging.
- UI: show node summary in the existing inspector pane; folder summary appears in folder header block and a read-only text field in the folder inspector.

## Risks / Trade-offs
- Longer prompts may increase latency; mitigation: cap prior-email context and body length, prefer snippets.
- Debounce may delay freshness; 30s chosen to prevent churn from rapid edits, but could feel slow—monitor and adjust.
- Cache growth from per-node entries; mitigate with size limits or LRU per scope.

## Migration Plan
- Introduce new cache entity/namespace; do not disturb existing thread summary cache. Provide migration guard to avoid double-generation during rollout.

## Open Questions
- Prompt length and token caps for body/prior context; to be finalized during implementation.
- Exact body snippet length and whether HTML is stripped server-side or in-app.
