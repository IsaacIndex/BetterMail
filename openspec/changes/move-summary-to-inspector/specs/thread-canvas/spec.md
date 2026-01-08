## MODIFIED Requirements
### Requirement: Node Content and Selection
The system SHALL render each node with sender, subject, and time, and SHALL update the inspector panel when a node is selected. When an Apple Intelligence summary is available for the selected thread, the inspector SHALL present a collapsible summary disclosure before the From field.

#### Scenario: Selecting a node
- **WHEN** the user clicks a node
- **THEN** the node is highlighted and the inspector panel shows that message's details

#### Scenario: Summary available for selected thread
- **WHEN** the selected thread has an Apple Intelligence summary
- **THEN** the inspector shows the summary disclosure above the From field with preview and expanded text states

#### Scenario: Summary unavailable for selected thread
- **WHEN** the selected thread lacks a summary or summaries are unsupported
- **THEN** the inspector omits the summary disclosure
