## Context
The current boundary-jump paths (latest and first) resolve a boundary message, expand day coverage, and emit a pending scroll request. In practice, two reliability gaps appear:
- Coverage expansion can stop before including very old targets (fixed step ceiling), so selection changes but no renderable jump target exists.
- Scroll execution depends on anchor availability at a specific render timing, so requests can be dropped when layout/anchor readiness lags selection.

## Goals / Non-Goals
- Goals:
  - Make both folder-header boundary jumps reliable across folder sizes and depths.
  - Keep interaction responsive during long-range jumps.
  - Ensure deterministic fallback when exact anchor targeting is unavailable.
- Non-Goals:
  - Change backfill/fetch scope beyond existing cache-only day expansion.
  - Alter folder ordering or canvas layout semantics.

## Decisions
- Decision: Introduce a stateful jump pipeline with explicit phases and cancellation boundaries.
  - Why: Prevents race conditions between selection updates, rethreading, and scroll-anchor readiness.

- Decision: Use adaptive bounded expansion rather than fixed count-limited stepping.
  - Why: Avoids both hard failure for long-history folders and excessive per-step churn.
  - Approach: expand in larger chunks initially, then tighten near the target day; cap total expansion work per jump and surface failure state when cap is reached.

- Decision: Make scrolling idempotent with retry-on-layout-change until success/timeout.
  - Why: The anchor layer may render after the first request; retries improve reliability without blocking UI.

- Decision: Define fallback target policy when exact target node is not renderable (for both oldest/newest boundaries).
  - Why: Keeps user-visible behavior predictable; nearest renderable node for the requested boundary in folder scope is used with preserved selection of the true boundary node.

## Risks / Trade-offs
- Additional state management increases view-model complexity.
  - Mitigation: Keep pipeline encapsulated in jump-specific helpers and structured logging.
- Larger expansion chunks can increase single-step compute cost.
  - Mitigation: Adaptive chunk sizing and throttled retry cadence.
- Retry loops can feel sticky if unbounded.
  - Mitigation: time-based retry deadline and explicit terminal states.

## Migration Plan
1. Add boundary-jump pipeline states and telemetry/logging.
2. Replace fixed expansion loop with adaptive bounded expansion.
3. Add anchor-ready retry semantics for pending scroll requests.
4. Add regression tests and manual validation scenarios.

## Open Questions
- Should a failed boundary-jump surface a visible status in the folder header, or remain log-only for now?
