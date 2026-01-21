## ADDED Requirements
### Requirement: Folder Header Inspector Entry
The system SHALL treat clicking a folder header on the thread canvas as a selection that opens the folder details panel in the inspector region, replacing any thread inspector content.

#### Scenario: Folder click shows details panel
- **WHEN** the user clicks a folder header
- **THEN** the inspector region shows the folder details panel instead of a thread inspector
- **AND** the previously selected thread is deselected
