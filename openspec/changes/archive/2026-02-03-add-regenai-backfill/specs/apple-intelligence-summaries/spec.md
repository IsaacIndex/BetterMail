## MODIFIED Requirements

### Requirement: Per-email Apple Intelligence summary
The system SHALL generate an Apple Intelligence summary for each email node using (1) the email's subject, (2) the email's body content, and (3) prior emails in the same thread up to that node, including any manually attached nodes that precede it.

#### Scenario: Range-based regeneration
- **WHEN** the user runs "Start Re-GenAI" for a date range in Settings
- **THEN** the system regenerates the per-email summaries for all nodes whose message dates fall within that range in the selected mailbox, even if a valid cache exists

### Requirement: Folder Apple Intelligence summary
The system SHALL generate a folder summary using the per-email summaries of all nodes in the folder and its subfolders, conveying what the threads in that folder are about (including manually attached nodes).

#### Scenario: Folder refresh after regeneration
- **WHEN** a batch of per-email summaries is regenerated via "Start Re-GenAI"
- **THEN** folder summaries for folders containing those emails (and their ancestor folders) are refreshed, respecting existing debounce rules
