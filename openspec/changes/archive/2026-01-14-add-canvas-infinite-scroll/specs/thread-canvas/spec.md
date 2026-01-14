## MODIFIED Requirements
### Requirement: Default Range and Column Order
The system SHALL default the canvas to the most recent 7 days, SHALL order thread columns by most recent activity, and SHALL allow the day range to expand in 7-day increments using cache-only paging when the user scrolls downward. Scroll detection SHALL be driven by GeometryReader updates of the canvas content frame so two-axis scrolling can still trigger paging.

#### Scenario: Default range and ordering
- **WHEN** the canvas loads
- **THEN** day bands cover the last 7 days and thread columns are ordered by latest message date

#### Scenario: Cache-only paging
- **WHEN** the user scrolls near the end of the current day range
- **THEN** the canvas expands by the next 7-day block using cached messages only

#### Scenario: Two-axis scroll detection
- **WHEN** the user scrolls the canvas vertically or diagonally
- **THEN** GeometryReader content-frame updates drive the scroll position used for paging

## ADDED Requirements
### Requirement: Visible-Range Backfill Action
The system SHALL expose a toolbar action when any visible day band has no cached messages, and SHALL backfill messages for only the currently visible day range on user request.

#### Scenario: Backfill button appears
- **WHEN** the visible viewport includes at least one day band with no cached messages
- **THEN** a toolbar backfill action is displayed

#### Scenario: Backfill fetch scope
- **WHEN** the user triggers the backfill action
- **THEN** the system fetches messages for only the visible day range and updates the cache before rethreading
