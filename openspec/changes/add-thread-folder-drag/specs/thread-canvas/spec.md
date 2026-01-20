## ADDED Requirements
### Requirement: Thread Folder Drag & Drop
The canvas SHALL allow dragging any thread node to move its entire thread into or out of folders, providing live visual feedback during the drag.

#### Scenario: Drag preview shows thread summary
- **WHEN** the user starts dragging a node
- **THEN** the drag preview shows the latest message subject in that thread and the total number of messages in the thread

#### Scenario: Drop onto folder joins it
- **WHEN** the user drags a thread over a folder column and drops
- **THEN** the folder border highlights while hovered and the thread becomes a member of that folder

#### Scenario: Drag out removes membership
- **WHEN** the user drags a thread that is in a folder and drops it onto non-folder canvas space
- **THEN** the thread is removed from its previous folder and the folder is deleted if it becomes empty

#### Scenario: Manual attachments remain coupled
- **WHEN** a thread with manually attached nodes is dragged into or out of a folder
- **THEN** the manual attachments stay grouped with that thread and connector rendering remains intact
