## ADDED Requirements
### Requirement: JWZ Canonical Thread Graph
The system SHALL keep using the JWZ algorithm to construct canonical trees per RFC 822 `Message-ID`, `In-Reply-To`, and `References` headers, recording envelope metadata (subject, sent date, participants, unread flags) on each node for provenance.

#### Scenario: Build canonical JWZ roots
- **GIVEN** a batch of fetched messages with the required headers
- **WHEN** the threader runs
- **THEN** it normalizes identifiers, produces parent/child chains for replies, prunes duplicate-subject placeholders, and outputs chronologically ordered JWZ roots with associated metadata ready for annotation

### Requirement: Apple Intelligence Thread Annotation
The system SHALL run Apple Intelligence analysis off the main actor to derive semantic embeddings, participant roles, topic tags, urgency/timeliness/personal-priority signals, and localized summaries per message, caching the results so UI layers never block on recomputation.

#### Scenario: Annotate messages asynchronously
- **GIVEN** JWZ nodes awaiting AI enrichment
- **WHEN** compatible hardware is available
- **THEN** the annotator batches message bodies + headers, requests embeddings/roles/tags/summary text, stores the annotations with cache keys per message ID, and surfaces capability status when Foundation Models are unavailable

### Requirement: Fragment Merge & Synthetic Conversation Parents
The system SHALL merge fragment subthreads (e.g., BCC forks or subject-renamed replies) when cosine similarity plus participant overlap exceed configured thresholds, and SHALL create synthetic parent nodes to represent latent conversations that lack header links, always preserving the original JWZ nodes as provenance annotated with merge reasons.

#### Scenario: Merge related fragments
- **GIVEN** two JWZ subtrees with high embedding similarity and at least one shared participant
- **WHEN** the merge engine runs
- **THEN** it attaches the fragment under a synthetic parent node labeled with the inferred topic, links back to the source JWZ root, and records human-readable merge justification so the UI and user controls can display and reverse the decision

### Requirement: Intent-aware Ordering Pipeline
The system SHALL start from the chronological JWZ traversal and re-rank threads by (1) Apple Intelligence intent relevance, urgency, and personal priority scores, (2) boosts for threads containing active tasks or unanswered questions, (3) user pinning/focus filters, and SHALL fall back to the original JWZ order to break ties deterministically.

#### Scenario: Re-rank threads deterministically
- **GIVEN** computed urgency/personal-priority signals plus user pin data
- **WHEN** the ordering pipeline runs
- **THEN** it produces a stable list where pinned and high-urgency threads rise above peers, task-focused conversations are boosted, focus filters hide non-matching groups, and any ties preserve the prior JWZ chronological ordering

### Requirement: ThreadGroup View Model Contract
The app SHALL expose a `ThreadViewModel` (ObservableObject, `@MainActor`) whose published `threads: [ThreadGroup]` wrap JWZ metadata, AI annotations (summary snippet, topic tags, urgency score, merge reasons), and computed relevance state so SwiftUI views only read ready-to-display groups.

#### Scenario: Deliver filtered thread groups
- **GIVEN** cached ThreadGroup data plus filter selection (“Priority”, “All”, “Waiting On Me”)
- **WHEN** the view model updates
- **THEN** it publishes the filtered `[ThreadGroup]`, exposes control bindings for user pinning/focus, and never triggers Apple Intelligence work on the main actor

### Requirement: Thread List Presentation
The SwiftUI inbox surface SHALL show a segmented control or filter chips for “Priority”, “All”, and “Waiting On Me”, and each thread cell SHALL display the subject, participant names with inferred roles, an AI-generated summary snippet, urgency/intent badges with VoiceOver-friendly labels, a stacked avatar row, and a LinearGradient accent derived from the primary topic tag.

#### Scenario: Render priority cell
- **GIVEN** a ThreadGroup marked urgent with active participants
- **WHEN** it appears in the list
- **THEN** the cell shows the subject + summary snippet, highlights participant roles (e.g., “Requester”, “Owner”), renders urgency badges and gradient accents tied to its topic tag, and constrains the layout to remain readable under Dynamic Type

### Requirement: Expandable Detail & Provenance View
Upon tapping a thread cell, the UI SHALL expand to show the JWZ tree with indented bubbles or a timeline, display AI-generated summaries per node, and insert labeled dividers (e.g., “Related conversation: Travel Plans”) where synthetic parents merge previously separate roots, along with controls to accept or revert the merge.

#### Scenario: Inspect related conversation
- **GIVEN** a ThreadGroup with merged latent conversations
- **WHEN** the user expands the detail view
- **THEN** the interface shows each JWZ child in temporal order, inserts a divider naming the inferred related conversation, and surfaces buttons/menus that let the user accept the merge or revert to separate JWZ threads while keeping provenance intact

### Requirement: Accessibility, Localization, and Summaries
All AI-generated summaries SHALL be wrapped in `LocalizedStringKey` or accompanied by localized fallback copy, summary text SHALL be exposed via `accessibilityHint`, urgency badges SHALL announce combined labels (e.g., “Urgent, awaiting reply”), and layouts SHALL remain accessible with Dynamic Type and VoiceOver.

#### Scenario: VoiceOver user reviews urgent thread
- **GIVEN** a user relying on VoiceOver and localized strings
- **WHEN** focus moves to an urgent ThreadGroup cell
- **THEN** VoiceOver announces the localized subject, AI summary hint, and urgency badge text, ensuring the user hears “Urgent, awaiting reply” (or localized equivalent) before activating the cell
