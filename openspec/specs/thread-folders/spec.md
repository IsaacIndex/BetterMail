# thread-folders Specification

## Purpose
TBD - created by archiving change add-thread-folders. Update Purpose after archive.
## Requirements
### Requirement: Folder Creation From Selection
The system SHALL allow users to create a folder from the currently selected nodes, capturing the effective thread IDs for all selected nodes (including manual attachments).

#### Scenario: Create folder
- **WHEN** the user invokes "Add to Folder" with one or more selected nodes
- **THEN** a new folder is created that contains the effective thread IDs represented by the selection

### Requirement: Folder Title Defaults
The system SHALL default the folder title to the subject of the latest message among the selected nodes, using the subject placeholder when missing.

#### Scenario: Default title
- **WHEN** a folder is created
- **THEN** its title matches the latest selected message subject (or the subject placeholder if empty)

### Requirement: Folder Color Persistence
The system SHALL assign each folder a random color on creation and SHALL persist that color across relaunches.

#### Scenario: Stable folder color
- **WHEN** the app is relaunched
- **THEN** folder colors are restored to their persisted values

### Requirement: Folder Persistence
The system SHALL persist folders and their member thread IDs so they are restored after refreshes and relaunches.

#### Scenario: Refresh retains folders
- **WHEN** the thread list refreshes
- **THEN** folders and their membership remain intact

### Requirement: Folder Visual Grouping
The system SHALL render a shared background block behind all threads in a folder using the folder's color.

#### Scenario: Folder background
- **WHEN** a folder is visible on the canvas
- **THEN** its member threads share a common background block tinted with the folder color

### Requirement: Sticky Folder Titles
The system SHALL render a folder title label at the top of the folder's thread region and SHALL keep it pinned to the top edge while the user scrolls within that folder's vertical extent.

#### Scenario: Sticky title behavior
- **WHEN** the user scrolls through a folder's threads
- **THEN** the folder title remains visible at the top until the folder's region is scrolled past

