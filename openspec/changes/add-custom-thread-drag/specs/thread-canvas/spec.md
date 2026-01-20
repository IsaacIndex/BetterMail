## ADDED Requirements
### Requirement: Custom Thread Drag (Canvas)
The system SHALL provide a custom drag interaction for single-thread drags on the thread canvas using DragGesture (not system drag), rendering a floating preview that follows the pointer without the system lift animation.

#### Scenario: Drag to folder column
- **WHEN** the user starts dragging a thread node and drops it onto a folder column
- **THEN** that thread is moved into the target folder
- **AND** the custom preview follows the pointer for the duration of the drag

#### Scenario: Drag out of folder to canvas
- **WHEN** the user drags a thread node currently in a folder and drops it on empty canvas area
- **THEN** the thread is removed from that folder
- **AND** the preview dismisses cleanly at drop end

#### Scenario: Drag manually attached node
- **WHEN** the user drags a node that is manually attached to a thread
- **THEN** the custom drag uses the thread for that node and supports the same folder drop outcomes

#### Scenario: Drag cancel safety
- **WHEN** the user cancels the drag (e.g., Escape or leaving the window)
- **THEN** the custom preview disappears and no move/remove occurs
