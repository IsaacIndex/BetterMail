## ADDED Requirements

### Requirement: Organizer Responsibility Boundaries
The system SHALL separate organizer projection, selection semantics, layout persistence, BetterMail mutation/ledger, suggestion policy, external Mail authorization/mutation, unified history, and measurement behind focused testable interfaces rather than adding those responsibilities directly to the existing hub types.

#### Scenario: View models delegate organizer work
- **WHEN** `ThreadCanvasViewModel` or `GraphCanvasViewModel` handles an Organize interaction
- **THEN** it delegates pure projection/selection, durable mutation, layout storage, or Mail effects to the corresponding focused boundary
- **AND** retains only source-state and presentation orchestration appropriate to that view model

#### Scenario: Automation coordinator orchestrates extracted policy
- **WHEN** Graph Automation builds sources, ranks a placement, persists a command, or requests Mail work
- **THEN** source construction and policy are pure testable units
- **AND** persistence and Mail execution go through the shared organizer boundaries

#### Scenario: Renderer does not own persistence
- **WHEN** `ObsidianGraphScene` resolves selection, drag, lasso, or a drop target
- **THEN** it emits normalized interaction intent
- **AND** does not write Group membership, layout files, operation history, or Apple Mail directly

#### Scenario: Legacy renderer is not expanded
- **WHEN** Organize behavior is implemented
- **THEN** production interaction work targets the mounted Obsidian renderer path
- **AND** the legacy graph renderer receives no duplicate feature implementation unless a separate approved proposal changes renderer ownership

#### Scenario: Boundary failures are deterministic
- **WHEN** tests inject in-memory stores, file failures, stale fingerprints, missing opaque-ID or route-encryption keys, unauthorized Mail gateways, unavailable suggestion providers, or partial external results
- **THEN** each boundary produces a domain-specific, observable result
- **AND** no error is silently swallowed

#### Scenario: Mail mutators cannot bypass the gateway
- **WHEN** production code creates an Apple Mail mailbox or moves/restores messages
- **THEN** the call requires the shared `OrganizationMailGateway`
- **AND** the exhaustive call-site regression matrix fails if a view model, coordinator, service, retry, or recovery path invokes a lower-level mutator directly
