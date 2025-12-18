## Context
BetterMail currently relies on `JWZThreader` for deterministic reply trees and exposes those nodes directly to SwiftUI via `ThreadSidebarViewModel`. Apple Intelligence is only used for a summary string per thread. The new requirement is to retain JWZ as provenance while layering semantic intent, embeddings, urgency scoring, and latent conversation merges that the UI can render with richer affordances, all without blocking the main actor.

## Goals / Non-Goals
- Goals: (1) keep JWZ roots intact for debugging, (2) add an async Apple Intelligence annotator that caches embeddings/summaries per message, (3) merge fragments/latent conversations with cosine-similarity + participant heuristics, (4) expose a `ThreadViewModel` that publishes `[ThreadGroup]` plus filter state, and (5) redesign the SwiftUI surfaces with accessibility + localization baked in.
- Non-Goals: Altering Mail fetch, touching MailKit helper behavior, or changing bundle identifiers/signing assets. We also avoid server-side storage; everything remains on-device.

## Decisions
1. **Two-phase graph build** — keep JWZ construction unchanged, then run an `IntentAnnotator` service off the main actor that ingests the JWZ graph, loads/caches embeddings + participant roles from Foundation Models, and emits `IntentAnnotations` for each message.
2. **ThreadGroup cache** — persist merged graphs plus AI scores (`ThreadGroup`, `IntentSignals`, `MergeJustification`) into the Core Data store so SwiftUI reads ready-to-display models instead of recomputing every refresh. Cache invalidation keys off message IDs + annotation version hash.
3. **Merge heuristics** — implement `FragmentMergeEngine` that (a) clusters JWZ nodes when cosine similarity & participant overlap exceed configurable thresholds, (b) emits synthetic parent nodes referencing contributing JWZ roots for latent conversations, and (c) records merge reason text for UI + user controls.
4. **Ordering pipeline** — after merges, compute chronological JWZ order, then re-rank via urgency/personal priority/task inference while honoring user pins/focus filters, falling back to JWZ order for deterministic ties. `ThreadViewModel` holds the filter state and publishes `[ThreadGroup]` slices for “Priority”, “All”, and “Waiting On Me”.
5. **SwiftUI presentation** — introduce thread cells with stacked avatars, participant role chips, AI summary snippet, urgency badges, and a LinearGradient accent mapped to topic tags. Detail view reveals the JWZ tree using indented bubbles or timeline plus labeled dividers for merged related conversations. Accessibility hints describe AI summaries/badges, and all user strings flow through `LocalizedStringKey`.
6. **User trust controls** — expose accept/revert merge actions per thread group, log choices, and fall back to JWZ-only view when AI is unavailable or a merge is reverted.

## Risks / Trade-offs
- Apple Intelligence availability varies by hardware; mitigation: annotator reports capability status and gracefully no-ops, leaving JWZ ordering intact.
- Semantic merges could be wrong, so we require per-thread user overrides and keep provenance for debugging.
- Computing embeddings for many messages could be expensive; mitigation: run analysis off the main actor, batch work, cache embeddings, and throttle refresh frequency.

## Migration Plan
1. Land the new models/services behind feature flags, still feeding `ThreadSidebarViewModel`.
2. Introduce `ThreadViewModel` that consumes cached `ThreadGroup` data; migrate SwiftUI list to the new model.
3. Remove obsolete summary-only UI once the new design is stable, ensuring fallback paths for Macs without Apple Intelligence.
4. Document cache-clearing + merge override flows for QA.

## Open Questions
- Exact cosine similarity/participant thresholds for merges (start with spec default 0.82 + at least one shared participant?).
- Where to persist embeddings: extend existing Core Data store vs. sidecar file? (leaning Core Data entity).
- Should urgency scoring treat calendar events differently from generic deadlines? Need product input.
