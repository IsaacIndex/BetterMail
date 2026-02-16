## ADDED Requirements
### Requirement: Move Selected Nodes to Existing Mailbox Folder
The system SHALL provide an action for selected canvas nodes to move their underlying messages into an existing Apple Mail mailbox folder, resolving messages from the selected node set (not Mail.app's current selection).

#### Scenario: Move selected nodes to existing destination
- **WHEN** the user selects one or more nodes and chooses an existing mailbox folder destination
- **THEN** BetterMail resolves message identifiers from the selected nodes
- **AND** BetterMail issues move commands targeting the chosen account/folder destination in Apple Mail

### Requirement: Create Mailbox Folder During Move Flow
The system SHALL let users create a new Apple Mail mailbox folder as part of the move flow by choosing destination account and parent folder.

#### Scenario: Create destination folder then move
- **WHEN** the user chooses "New Mailbox Folder" from the move action and provides folder name + destination account/parent
- **THEN** BetterMail creates the mailbox folder in Apple Mail under the selected parent scope
- **AND** BetterMail moves the selected-node messages into the newly created mailbox folder

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
