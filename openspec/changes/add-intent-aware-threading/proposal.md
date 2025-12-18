# Change: Intent-aware Threading Pipeline

## Why
JWZ threading already produces deterministic reply trees, but BetterMail currently renders those structures directly and only surfaces a single AI summary per thread. The product brief now requires blending canonical JWZ trees with Apple Intelligence analysis so the inbox can spot latent relationships, merge fragmented conversations, and re-rank threads by intent, urgency, and personal priority cues. Without a proposal we risk bolting AI heuristics straight onto UI code, duplicating work, and lacking clear guarantees around provenance, accessibility, or user control when merges are wrong.

## What Changes
- Introduce an intent-aware threading capability that layers Apple Intelligence annotations on top of JWZ output: embeddings, participant roles, topic tags, urgency/timeliness/personal priority scoring, and cached natural-language summaries.
- Define merge heuristics that use cosine similarity plus participant overlap to stitch BCC forks or subject-renamed fragments while preserving the original JWZ nodes as provenance and exposing accept/revert controls.
- Model latent conversations as synthetic parent nodes tying together related JWZ roots when intent or topic similarity exceeds thresholds, and annotate those joins so the UI can render labeled dividers (e.g., “Related conversation: Travel Plans”).
- Replace the ad-hoc sidebar state with a dedicated `ThreadViewModel` that publishes `[ThreadGroup]` collections ready for SwiftUI filters (“Priority”, “All”, “Waiting On Me”), so the UI only performs presentation work.
- Update the SwiftUI presentation spec to require summary snippets, participant role chips, urgency badges with accessibility labels, stacked avatars, gradient accents by topic, expandable JWZ trees, and localized accessibility hints for AI-generated text.

## Impact
- Affected specs: intent-threading
- Affected code: Threading pipeline (`JWZThreader`, new AI annotator/merger), storage/caching for embeddings & annotations, `ThreadSidebarViewModel` replacement, SwiftUI inbox list + detail surfaces, EmailSummary services for summaries/localization, user preference surfaces for merge controls.
