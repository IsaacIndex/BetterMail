## ADDED Requirements
### Requirement: Move Selected Threads to Existing Mailbox Folder
The system SHALL provide an action for selected canvas nodes that moves all cached messages in the corresponding thread(s) into an existing Apple Mail mailbox folder, resolving message targets from BetterMail data (not Mail.app's current selection).

#### Scenario: Move selected thread messages to existing destination
- **WHEN** the user selects one or more nodes and chooses an existing mailbox folder destination
- **THEN** BetterMail expands the selection to all cached messages in the selected thread(s)
- **AND** BetterMail resolves message identifiers for every message in that expanded set
- **AND** BetterMail issues move commands targeting the chosen account/folder destination in Apple Mail
- **AND** BetterMail aborts the move if any required message is ambiguous or unresolved

### Requirement: Create Mailbox Folder During Move Flow
The system SHALL let users create a new Apple Mail mailbox folder as part of the move flow by choosing destination account and parent folder, then apply thread-scoped move semantics.

#### Scenario: Create destination folder then move
- **WHEN** the user chooses "New Mailbox Folder" from the move action and provides folder name + destination account/parent
- **THEN** BetterMail creates the mailbox folder in Apple Mail under the selected parent scope
- **AND** BetterMail moves all cached messages in the selected thread(s) into the newly created mailbox folder when all required message targets are resolvable

### Requirement: Persistent Thread Auto-Follow for Mailbox Moves
The system SHALL persist mailbox destination rules per account/thread for successful thread-scoped moves so future off-destination messages in those threads are automatically moved.

#### Scenario: Future message arrives in tracked thread
- **GIVEN** the user has previously moved a thread to a mailbox folder
- **WHEN** a later refresh includes messages in that same thread that are not already in the tracked destination
- **THEN** BetterMail attempts to move those off-destination thread messages to the tracked mailbox destination

### Requirement: Single-Account Guard for Move/Create Actions
The system SHALL gate mailbox-folder move/create actions to node selections that resolve to a single account.

#### Scenario: Mixed-account selection
- **WHEN** selected nodes include messages from multiple accounts
- **THEN** mailbox-folder move/create actions are disabled or blocked with inline guidance
- **AND** no Apple Mail folder mutation is attempted

### Requirement: Post-Action Hierarchy and Scope Refresh
The system SHALL refresh mailbox hierarchy and active mailbox-scope data after successful mailbox-folder create/move operations.

#### Scenario: Destination reflects mutation
- **WHEN** a mailbox-folder create or move action succeeds
- **THEN** the sidebar hierarchy refreshes to include destination changes
- **AND** the currently active mailbox scope content is refreshed to reflect moved messages
