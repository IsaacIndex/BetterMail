## ADDED Requirements
### Requirement: Account-Aware Mailbox Hierarchy
The system SHALL read Apple Mail account and mailbox folder hierarchy and represent nested subfolders as a tree that preserves parent-child relationships.

#### Scenario: Hierarchy fetch succeeds
- **WHEN** BetterMail requests mailbox hierarchy data from Apple Mail
- **THEN** the result includes account-level roots and nested mailbox folders with stable account/path metadata for each node

### Requirement: Default Scope Remains All Inboxes
The system SHALL keep `All Inboxes` as the default active mailbox scope when the app launches.

#### Scenario: Launch defaults to aggregate scope
- **WHEN** the app starts and mailbox hierarchy is available
- **THEN** the active scope is `All Inboxes`
- **AND** the canvas continues to load aggregated inbox content unless the user explicitly selects another mailbox scope

### Requirement: Mailbox Sidebar Tree UI
The system SHALL display mailbox accounts and nested mailbox folders in a sidebar UI with expand/collapse behavior and folder selection.

#### Scenario: Expand account and view subfolders
- **WHEN** the user expands an account in the sidebar
- **THEN** the sidebar reveals that account's mailbox folders and nested subfolders using the Apple Mail hierarchy order

#### Scenario: Select mailbox folder
- **WHEN** the user selects a mailbox folder in the sidebar
- **THEN** the selected mailbox folder is visually indicated in the sidebar
- **AND** the active mailbox scope switches to the selected account/folder

### Requirement: Scoped Canvas Data by Mailbox Selection
The system SHALL drive canvas refresh/rethread data scope from the active mailbox selection (All Inboxes or a selected account/folder scope).

#### Scenario: Switch from All Inboxes to a subfolder
- **WHEN** the user selects a subfolder under an account while viewing `All Inboxes`
- **THEN** subsequent data load/rethread operations use that selected account/folder scope
- **AND** the canvas reflects only messages from the selected mailbox scope
