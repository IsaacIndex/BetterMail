## ADDED Requirements
### Requirement: Pinned Folder Action
The system SHALL allow users to pin or unpin a folder from the folder header context menu.

#### Scenario: Pin folder
- **WHEN** the user opens a folder header context menu and selects "Pin Folder"
- **THEN** the folder is marked as pinned

#### Scenario: Unpin folder
- **WHEN** the user opens a pinned folder header context menu and selects "Unpin Folder"
- **THEN** the folder is marked as unpinned

### Requirement: Pinned Folder Ordering
The system SHALL display pinned folders before unpinned folders in the folder list while preserving the existing order within each group.

#### Scenario: Pinned folders sort first
- **WHEN** one or more folders are pinned
- **THEN** pinned folders appear before unpinned folders in the folder list
- **AND** the relative order of pinned folders matches the original folder order
- **AND** the relative order of unpinned folders matches the original folder order

### Requirement: Pinned Folder Indicator
The system SHALL display a pin icon at the top-right corner of the header for pinned folders.

#### Scenario: Pinned icon visible
- **WHEN** a folder is pinned
- **THEN** its header shows a pin icon in the top-right corner

### Requirement: Pinned Folder Persistence
The system SHALL persist pinned folder state locally so it is restored after relaunch.

#### Scenario: Relaunch restores pins
- **WHEN** the app is relaunched after pinning folders
- **THEN** the same folders remain pinned
