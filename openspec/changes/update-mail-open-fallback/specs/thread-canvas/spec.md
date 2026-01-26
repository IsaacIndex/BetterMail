## MODIFIED Requirements
### Requirement: Node Content and Selection
The system SHALL render each node with sender, subject, and time, and SHALL update the inspector panel when a node is selected. The inspector panel SHALL present a body preview trimmed to 10 lines with an ellipsis when the message body exceeds 10 lines, and SHALL provide an "Open in Mail" button to view the full message in Apple Mail. The "Open in Mail" control SHALL normalize the Message-ID before launching Mail and SHALL surface an inline failure state (e.g., when Mail returns `MCMailErrorDomain` error 1030) that offers a fallback search to locate the message.

#### Scenario: Selecting a node
- **WHEN** the user clicks a node
- **THEN** the node is highlighted and the inspector panel shows that message's details with a 10-line body preview and an "Open in Mail" button

#### Scenario: Large body preview
- **WHEN** the selected message body exceeds 10 lines
- **THEN** the inspector preview shows the first 10 lines followed by an ellipsis and does not render the full body

#### Scenario: Open in Mail failure surfaces fallback
- **WHEN** the user triggers "Open in Mail" and Mail returns an error instead of opening the URL
- **THEN** the inspector shows that the direct open failed and presents a fallback search action without requiring the user to reselect the node

## ADDED Requirements
### Requirement: Open in Mail Fallback Search
When direct Mail open fails, the system SHALL search Apple Mail for the selected message's Message-ID via AppleScript and SHALL present the best match (subject, sender, and received date) in the inspector with actions to open that message in Mail without relying on `message://`, copy the Message-ID, and copy the message URL. The search SHALL run asynchronously and expose a loading and completion state.

#### Scenario: Fallback search success shows result
- **WHEN** direct open fails and the fallback search finds a message with the same Message-ID
- **THEN** the inspector shows its subject, sender, and received date with an action to open that message in Mail
- **AND** copy actions for the Message-ID and message URL remain available

#### Scenario: Fallback search no match guidance
- **WHEN** the fallback search completes without a match
- **THEN** the inspector shows that no match was found
- **AND** the user can copy the Message-ID and message URL to search manually in Mail
