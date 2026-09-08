## MODIFIED Requirements

### Requirement: Folder Creation From Selection
The system SHALL allow users to create a confirmed BetterMail Group from the current selection, capturing the deduplicated effective thread IDs for all selected nodes, including manual attachments and Organize rail/graph selections. Creation and membership SHALL commit in one atomic BetterMail transaction bracketed by a durable write-ahead organization operation; any requested graph anchor SHALL be recorded as a replayable intent and separate receipt rather than falsely treated as part of the Core Data transaction.

#### Scenario: Create folder
- **WHEN** the user invokes Add to Folder with one or more selected nodes
- **THEN** a new folder is created that contains the effective thread IDs represented by the selection

#### Scenario: Create Group from Organize empty-canvas drop
- **WHEN** the user confirms a valid inline name after dropping at least two selected effective conversations on empty Organize canvas
- **THEN** one confirmed Group and all eligible memberships commit in one BetterMail transaction after its durable prepared record is written
- **AND** a ledger-boundary failure resumes idempotently without duplicating membership
- **AND** the intended graph anchor is completed through a separate idempotent receipt

#### Scenario: Folder creation fails atomically
- **WHEN** the Group creation or membership transaction fails
- **THEN** no partial Group membership or falsely completed History record remains
- **AND** no spatial anchor is applied as if creation succeeded

### Requirement: Folder Persistence
The system SHALL persist folders, their member effective thread IDs, and the corresponding durable organization operation so semantic organization is restored after refreshes and relaunches. Spatial anchor persistence SHALL remain a separate recoverable presentation concern and SHALL NOT determine whether valid folder membership exists.

#### Scenario: Refresh retains folders
- **WHEN** the thread list refreshes
- **THEN** folders and their membership remain intact

#### Scenario: Relaunch completes missing anchor receipt
- **GIVEN** folder membership committed but its intended Organize anchor receipt is missing
- **WHEN** the app relaunches
- **THEN** the folder and membership restore immediately
- **AND** recovery idempotently writes the missing anchor without duplicating the folder

#### Scenario: Undo preserves later folder edits
- **GIVEN** a later user edit changed the folder or its membership after the recorded operation
- **WHEN** the user requests Undo from organization History
- **THEN** current fingerprints are checked
- **AND** the app requests review instead of overwriting the later edit
