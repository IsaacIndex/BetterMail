## ADDED Requirements
### Requirement: Nested Folder Creation
The system SHALL allow creating a child folder from a thread that is already inside a folder, placing the new folder beneath the parent while keeping the parent folder as the owner of the child. Parents MAY contain multiple child folders and MAY also contain loose member threads.

#### Scenario: Create child from existing folder member
- **WHEN** the user selects a node inside folder A and invokes "Add to Folder"
- **THEN** a new folder B is created as a child of folder A
- **AND** the selected thread becomes a member of folder B
- **AND** folder A retains folder B as a child

#### Scenario: Parent keeps loose threads
- **WHEN** a child folder is created from one of several threads in folder A
- **THEN** folder A continues to contain its remaining member threads alongside the new child folder

#### Scenario: Multiple child folders
- **WHEN** the user repeats child creation on other threads within folder A
- **THEN** additional child folders are added under folder A without limiting depth

### Requirement: Nested Folder Persistence
The system SHALL persist parent-child relationships between folders and their member thread IDs so the hierarchy is restored after refreshes and relaunches.

#### Scenario: Relaunch restores hierarchy
- **WHEN** the app is relaunched
- **THEN** nested folders, their child links, and all thread memberships are restored

### Requirement: Nested Folder Visual Stacking
The system SHALL render stacked headers for nested folders so that each parent header appears above its children, expands its height to fit the stack, and widens its border/background to encapsulate the visible area of its child headers and body content.

#### Scenario: Two-level stack
- **WHEN** folder A contains child folder B
- **THEN** folder A's header renders above folder B's header, with folder A's background/border extending around folder B's header and body area

#### Scenario: Multi-level depth
- **WHEN** a folder contains grandchildren or deeper levels
- **THEN** each ancestor header increases the stack height to fit all descendant headers and maintains a border that encloses the full nested stack
