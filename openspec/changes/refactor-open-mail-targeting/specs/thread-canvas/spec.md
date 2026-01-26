## MODIFIED Requirements
### Requirement: Node Content and Selection
The system SHALL render each node with sender, subject, and time, and SHALL update the inspector panel when a node is selected. The inspector panel SHALL present a body preview trimmed to 10 lines with an ellipsis when the message body exceeds 10 lines, and SHALL provide an "Open in Mail" control that uses AppleScript-based targeting only (no `message://` URLs). The control SHALL first attempt a case-insensitive Message-ID lookup (accepting bracketed or unbracketed forms) and, on failure, SHALL fall back to metadata-based heuristics before surfacing an inline failure state with copy actions.

#### Scenario: Selecting a node
- **WHEN** the user clicks a node
- **THEN** the node is highlighted and the inspector panel shows that message's details with a 10-line body preview and an "Open in Mail" control

#### Scenario: Large body preview
- **WHEN** the selected message body exceeds 10 lines
- **THEN** the inspector preview shows the first 10 lines followed by an ellipsis and does not render the full body

#### Scenario: Open in Mail AppleScript targeting
- **WHEN** the user triggers "Open in Mail"
- **THEN** the app uses AppleScript to select and open the message by Message-ID without invoking `message://`, accepting both bracketed and unbracketed forms and ignoring case

#### Scenario: Inline status after targeting failure
- **WHEN** AppleScript targeting cannot find or open the message
- **THEN** the inspector shows a failure status with copy actions (Message-ID and subject) instead of attempting a URL

## ADDED Requirements
### Requirement: Heuristic Mail Targeting
When direct Message-ID lookup fails, the system SHALL attempt AppleScript-based heuristics recommended in Apple Support thread 253933858: constrain search using cached mailbox and account hints when available, and otherwise search by subject + sender + received-date within Mail. The inspector SHALL surface which heuristic succeeded (Message-ID match vs. metadata heuristic) or that no match was found.

#### Scenario: Mailbox-scoped heuristic
- **WHEN** Message-ID lookup fails but mailbox or account hints exist for the selected message
- **THEN** the system searches that mailbox/account for a message matching the cached subject + sender + received date and opens the first match in Mail

#### Scenario: Global heuristic without mailbox hint
- **WHEN** Message-ID lookup fails and no mailbox hint is available
- **THEN** the system searches across Mail for the first message whose subject, sender, and received date match the cached metadata and opens it in Mail

#### Scenario: Status reflects heuristic outcome
- **WHEN** a heuristic succeeds or fails
- **THEN** the inspector status text indicates the path used (Message-ID match, heuristic match, or no match) and keeps copy actions available for manual search
