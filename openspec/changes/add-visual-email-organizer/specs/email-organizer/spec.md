## ADDED Requirements

### Requirement: First-Class Organize Workspace
The system SHALL present the existing stored Graph mode to users as **Organize** and SHALL render a collapsible Unorganized rail beside the active Obsidian graph canvas while preserving Default and Timeline as peer presentations.

#### Scenario: Enter Organize without changing scope
- **GIVEN** a mailbox scope and search query are active
- **WHEN** the user selects Organize
- **THEN** the same scope and query remain active
- **AND** the Unorganized rail and graph canvas become available without a mailbox refetch caused only by the presentation change

#### Scenario: Existing Graph preference migrates
- **GIVEN** a user previously stored the internal `.graph` presentation value
- **WHEN** the upgraded app loads that setting
- **THEN** the app presents Organize
- **AND** does not reset the user's other graph settings

#### Scenario: Narrow workspace remains operable
- **WHEN** the rail, canvas, and inspector cannot fit at the current window width
- **THEN** the rail collapses or condenses before covering the canvas, inspector, or organization action bar
- **AND** an accessible control remains available to reopen it

### Requirement: Scoped Unorganized Projection
The system SHALL derive exactly one Unorganized row for each visible effective BetterMail conversation in the active mailbox scope and search result that is not in Graph Archive and has no membership in any confirmed BetterMail `ThreadFolder`.

#### Scenario: Folderless effective conversation appears once
- **GIVEN** a visible effective conversation contains multiple message nodes and has no confirmed Group membership
- **WHEN** Organize is open
- **THEN** exactly one Unorganized row appears for that effective conversation

#### Scenario: Apple Mail location does not imply organization
- **GIVEN** a visible effective conversation is stored in an Apple Mail mailbox but has no BetterMail Group membership
- **WHEN** Organize computes the Unorganized projection
- **THEN** the conversation remains Unorganized

#### Scenario: Suggestion does not imply organization
- **GIVEN** a visible conversation is only a member of an unconfirmed suggested Group
- **WHEN** Organize computes the Unorganized projection
- **THEN** the conversation remains Unorganized until a confirmed Group mutation commits

#### Scenario: Confirmed membership updates the rail
- **WHEN** a Group assignment commits and the threaded projection refreshes
- **THEN** the assigned conversation disappears from Unorganized
- **AND** failed or rolled-back assignments leave the row present

### Requirement: Shared Search and Selection
The system SHALL use one effective-conversation selection authority across the Unorganized rail, graph canvas, inspector, and organization action bar, and SHALL preserve the existing search semantics across those surfaces.

#### Scenario: Rail selection synchronizes every surface
- **WHEN** the user selects an Unorganized row
- **THEN** the corresponding effective conversation is selected on the graph
- **AND** the row, inspector, selected count, and action bar reflect the same selection

#### Scenario: Command-click toggles selection
- **WHEN** the user Cmd-clicks a selectable rail row or graph conversation
- **THEN** that effective conversation is toggled without discarding the other selected conversations

#### Scenario: Shift-click extends a deterministic range
- **GIVEN** a selection anchor exists in the current visible order
- **WHEN** the user Shift-clicks another rail row or graph conversation
- **THEN** every selectable effective conversation in the inclusive deterministic range becomes selected

#### Scenario: Lasso selects in world coordinates
- **WHEN** the user Shift-drags, or enables Select Area and drags from blank canvas, over graph conversation marks
- **THEN** the system selects the eligible effective conversations whose defined hit geometry intersects the lasso
- **AND** holding Command adds the lasso result to the existing selection
- **AND** a node-origin drag remains a normal direct-manipulation drag while Select Area is enabled
- **AND** an unmodified blank-canvas drag continues to pan while Select Area is off

#### Scenario: Scope change reconciles stale selection
- **WHEN** the active mailbox scope changes
- **THEN** selected identifiers that are not valid in the new projection are removed before the rail and canvas present the new scope

### Requirement: Direct Batch Grouping
The system SHALL let users organize one or more selected effective conversations through a single deliberate Group mutation, with one visible target and no partial BetterMail membership result.

#### Scenario: Drop selected conversations on confirmed Group
- **GIVEN** one or more effective conversations are selected
- **WHEN** the selected batch is dropped on an eligible confirmed Group
- **THEN** exactly that Group is highlighted as the target
- **AND** one atomic BetterMail membership command assigns every eligible selected conversation
- **AND** the success state is visibly confirmed and added to History

#### Scenario: Nested targets resolve deterministically
- **GIVEN** eligible nested Group targets overlap
- **WHEN** the pointer is inside more than one target
- **THEN** the deepest eligible Group wins
- **AND** ties resolve to the smallest containing target

#### Scenario: Mapped Group drop remains app-only
- **GIVEN** the confirmed target Group has an optional Apple Mail mailbox mapping
- **WHEN** the selected conversations are dropped on that Group
- **THEN** only BetterMail Group membership changes
- **AND** a physical Apple Mail move requires a separate disclosed and authorized command

#### Scenario: Suggested and virtual targets reject drops
- **WHEN** a selected batch is dropped on a ghost suggested Group or virtual remainder node
- **THEN** no membership mutation occurs
- **AND** the UI explains that the target must be confirmed or expanded first

#### Scenario: Invalid or cancelled drop is mutation-free
- **WHEN** a drag is cancelled or released on an invalid target
- **THEN** no BetterMail Group membership changes
- **AND** no Apple Mail call occurs

### Requirement: Empty-Canvas Group Creation
The system SHALL support creating a confirmed Group from a multi-conversation selection by dropping it on empty canvas and completing an accessible inline naming step.

#### Scenario: Multi-selection opens inline composer
- **GIVEN** at least two effective conversations are selected
- **WHEN** the selected batch is dropped on empty canvas
- **THEN** an inline localized Group-name composer opens at the intended canvas location
- **AND** membership is not changed before the composer is confirmed

#### Scenario: Valid name commits one Group operation
- **WHEN** the user confirms a non-blank trimmed Group name
- **THEN** one confirmed Group is created
- **AND** all eligible selected conversations commit atomically in the BetterMail store after a durable prepared organization record captures the intended Group anchor
- **AND** an interrupted ledger boundary resumes from fingerprints without duplicating membership
- **AND** the separate spatial store writes an anchor receipt before the operation reports complete

#### Scenario: Anchor write recovers after semantic commit
- **GIVEN** Group creation and membership committed but the separate spatial anchor write did not
- **WHEN** the app relaunches or recovery resumes
- **THEN** the durable anchor intent is replayed into the spatial store
- **AND** the valid Group membership is not rolled back or duplicated

#### Scenario: Blank name is rejected safely
- **WHEN** the user submits an empty or whitespace-only name
- **THEN** the composer presents a validation message
- **AND** no Group or membership record is created

#### Scenario: Single conversation repositions only
- **GIVEN** exactly one conversation is selected
- **WHEN** it is dropped on empty canvas
- **THEN** its spatial position changes
- **AND** its Group membership does not change

### Requirement: Scoped Spatial Memory
The system SHALL persist stable graph-node positions, confirmed Group anchors, zoom, and pan per opaque scope token derived from `MailboxScope.graphPagingScopeID` and SHALL restore them before the corresponding scene is presented after refresh or relaunch.

#### Scenario: Relaunch restores spatial context
- **GIVEN** the user arranged a scope and the settled state was saved
- **WHEN** BetterMail relaunches into that scope
- **THEN** the saved stable positions, Group anchors, zoom, and pan are restored without an initial layout jump

#### Scenario: Scope state is isolated
- **GIVEN** two mailbox scopes have different saved layouts
- **WHEN** the user switches between them
- **THEN** each scope restores only its own state

#### Scenario: Missing or corrupt state falls back safely
- **WHEN** the active scope has missing, corrupt, or unsupported-future layout data
- **THEN** the graph uses the deterministic seeded layout
- **AND** remains available without deleting other valid scope states

#### Scenario: Stable hidden identifiers survive paging
- **WHEN** a stable thread, message, or Group is temporarily hidden by paging or filtering
- **THEN** its stored position is retained
- **AND** virtual remainder identifiers are never persisted

#### Scenario: Spatial file contains opaque identifiers only
- **WHEN** the spatial state file is inspected
- **THEN** scope, node, and Group keys are non-reversible per-install opaque tokens
- **AND** no raw message, thread, account, mailbox, subject, sender, body, or snippet value appears

#### Scenario: Reset affects the active scope only
- **WHEN** the user confirms Reset Layout
- **THEN** only the active scope's spatial state is cleared
- **AND** semantic Group membership and other scopes remain unchanged

### Requirement: Task-First Controls
The system SHALL keep search, Unorganized state, selected count, Group, Move, Archive, and Undo/History in the primary organization workflow and SHALL place paging, display, physics, and diagnostic tuning under one Advanced disclosure.

#### Scenario: Primary actions are available without Advanced
- **WHEN** the user opens Organize with Advanced collapsed
- **THEN** every core organization action remains discoverable and operable

#### Scenario: Existing tuning settings remain compatible
- **GIVEN** the user has stored paging, display, or force settings
- **WHEN** those controls move under Advanced
- **THEN** the prior values and behavior are preserved

### Requirement: Accessible Organization Parity
The system SHALL provide localized labels and hints, stable opaque identifiers, selected traits, keyboard operation, VoiceOver activation, Dynamic Type support, Reduce Transparency fallback, and non-color selection cues for every core Organize interaction. Organizer element identifiers SHALL follow `bettermail.organizer.<role>.<opaque-token>` and SHALL never embed a raw message, thread, account, or mailbox identifier.

#### Scenario: Core action is not gesture-only
- **GIVEN** a user cannot perform graph drag gestures
- **WHEN** the user navigates the Unorganized rail or action menu by keyboard or VoiceOver
- **THEN** the user can select conversations, create or choose a Group, confirm effects, and undo the result

#### Scenario: Regular graph nodes expose semantic state
- **WHEN** VoiceOver focuses a selectable conversation or confirmed Group node
- **THEN** it announces the localized role, identifying label, selection state, and available activation action

#### Scenario: Accessibility descriptors are testable without SpriteKit
- **WHEN** the graph projection produces selectable conversation and Group nodes
- **THEN** a pure accessibility-descriptor seam exposes each element's role, localized label, selected state, activation intent, and opaque stable identifier for deterministic tests
