## Context
BetterMail’s primary surfaces currently enforce dark appearance in several UI paths (`.colorScheme(.dark)` modifiers in navigation and inspector surfaces). This breaks alignment with macOS appearance settings and blocks light mode for users who prefer it.

The requested change requires:
- System-default appearance on first launch
- In-app appearance override from Settings
- Preserved glassmorphism aesthetics and unchanged feature behavior

## Goals / Non-Goals
- Goals:
  - Add a user-facing appearance control in Settings.
  - Support `System`, `Light`, and `Dark` appearance modes.
  - Keep visual treatment coherent across navigation, canvas, and inspectors in both appearances.
  - Avoid behavioral regressions in refresh, threading, selection, and inspector workflows.
- Non-Goals:
  - Redesigning the app’s visual language beyond necessary light/dark adaptation.
  - Introducing new animation systems or third-party theming frameworks.
  - Changing data models unrelated to appearance preferences.

## Decisions
- Decision: Introduce a dedicated appearance settings model backed by `@AppStorage`.
  - Why: Matches existing settings patterns, persists across launches, and keeps implementation small.
  - Alternatives considered:
    - One-off `@AppStorage` bindings in views: simpler short term, but scatters appearance logic.
    - Central custom theming engine: too heavy for this scope.

- Decision: Apply appearance preference at app scene root via a single preferred color scheme mapping.
  - Why: Ensures consistent behavior across all windows/views with minimal plumbing.
  - Alternatives considered:
    - Per-view overrides only: high risk of inconsistencies and missed surfaces.

- Decision: Convert hard-coded dark-only styling decisions into appearance-aware style branches while preserving current glass treatment structure.
  - Why: Preserves existing aesthetics and avoids a full visual rewrite.
  - Alternatives considered:
    - Keep forced-dark glass on some components: would violate user-selected light mode and create mismatched UI.

## Risks / Trade-offs
- Risk: Light mode could reduce contrast in translucent layers.
  - Mitigation: Keep Reduce Transparency fallbacks and tune stroke/fill/foreground tokens for both schemes.

- Risk: Scene-level appearance override may affect sheets/popovers unexpectedly.
  - Mitigation: Validate settings window, backfill sheets, and inspector overlays under each appearance mode.

- Trade-off: Tri-state appearance option (`System`, `Light`, `Dark`) is slightly more UI than a single light-mode toggle.
  - Rationale: Better aligns with “default to computer settings but configurable” and future-proofs preferences.

## Migration Plan
1. Add new appearance settings model and persistence keys with safe defaults.
2. Wire settings model into app/root and settings view.
3. Replace hard-coded dark-mode forcing with appearance-aware behavior.
4. Tune glass foreground/background tokens for both appearances.
5. Validate parity (behavior unchanged) and build successfully.

## Open Questions
- None blocking for proposal scope.
