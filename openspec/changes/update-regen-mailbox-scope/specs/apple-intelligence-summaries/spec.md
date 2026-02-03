## ADDED Requirements
### Requirement: Regeneration honors mailbox scope
The system SHALL run summary regeneration against the same mailbox scope used by MessageStore (including the aggregated “All Inboxes”) instead of assuming a hardcoded mailbox name.

#### Scenario: Regenerate across All Inboxes
- **WHEN** the user starts Re-GenAI from Settings over a date range where messages exist in “All Inboxes”
- **THEN** the system counts and regenerates those messages (count > 0) without requiring the mailbox to be named “inbox”
