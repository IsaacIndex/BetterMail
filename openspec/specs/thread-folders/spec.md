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

### Requirement: Folder Details Editing
The system SHALL allow users to edit a folder's title from a details panel surfaced from the canvas.

#### Scenario: Edit title from header click
- **WHEN** the user clicks a folder header on the canvas
- **THEN** a folder details panel opens in the inspector region
- **AND** the panel shows the current folder title in an editable field
- **AND** saving updates the folder title on the canvas

### Requirement: Folder Color Editing
The system SHALL allow users to update a folder's background color from the folder details panel with immediate visual feedback.

#### Scenario: Update folder color
- **WHEN** the user adjusts the color in the folder details panel
- **THEN** the folder's background on the canvas updates to match the new color
- **AND** the chosen color is persisted

### Requirement: Persist Edited Folder Details
The system SHALL persist edited folder titles and colors so they are restored after refreshes and relaunches.

#### Scenario: Relaunch retains edits
- **WHEN** the app is relaunched after editing a folder's title or color
- **THEN** the folder is restored with the edited title and color

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

