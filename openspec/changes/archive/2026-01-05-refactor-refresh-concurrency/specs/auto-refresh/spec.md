## ADDED Requirements
### Requirement: Refresh Responsiveness
The system SHALL keep refresh heavy work off the main actor while applying UI-facing state on the main actor.

#### Scenario: Background refresh execution
- **WHEN** a refresh rebuilds threads and generates summaries
- **THEN** thread reconstruction and summary generation run in detached background tasks that do not inherit `@MainActor`, and roots, unread totals, status, and summary state are updated on the main actor only.

#### Scenario: Initial refresh on start
- **WHEN** the app initializes and triggers its first refresh
- **THEN** the initial threading and summary work run in detached background tasks with UI state changes (roots, unread totals, status, summaries, `isRefreshing`) applied on the main actor.

#### Scenario: Refresh flag reset
- **WHEN** a refresh completes, fails, or exits early
- **THEN** `isRefreshing` is set to `false` on the main actor so subsequent refreshes are unblocked.
