# Change: Cache Apple Intelligence thread summaries

## Why
- Apple Intelligence summaries are regenerated on every load, slowing startup and consuming compute even when the underlying threads are unchanged.
- Persisting summaries reduces redundant model invocations and keeps summaries available when the provider is temporarily unavailable.

## What Changes
- Store Apple Intelligence thread summaries in the local Core Data store with metadata (fingerprint + timestamps) tied to the thread root.
- Reuse cached summaries when inputs are unchanged; invalidate and regenerate when the thread's subjects/membership change.
- Surface cached status in the UI so users know whether a summary is fresh or reused.

## Impact
- Affected specs: `thread-summaries` (new capability).
- Affected code: `MessageStore` schema/model, summary pipeline in `ThreadCanvasViewModel`, summary provider wiring, any UI that displays Apple Intelligence summaries.
