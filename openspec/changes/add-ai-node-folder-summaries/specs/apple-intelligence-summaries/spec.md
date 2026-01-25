## ADDED Requirements
### Requirement: Per-email Apple Intelligence summary
The system SHALL generate an Apple Intelligence summary for each email node using (1) the email's subject, (2) the email's body content, and (3) prior emails in the same thread up to that node, including any manually attached nodes that precede it.

#### Scenario: Node summary with subject and body
- **WHEN** an email node is selected
- **THEN** its summary is generated using its subject and body content plus a digest of prior emails in the thread (including manually attached nodes before it) to highlight what this email is about and what is new compared to earlier messages

### Requirement: Node summary regeneration on upstream changes
The system SHALL invalidate and regenerate an email node's summary when upstream thread content prior to that node changes (e.g., new earlier messages fetched, or manually attached nodes inserted before it).

#### Scenario: Regenerate after new prior email
- **WHEN** a new earlier email is fetched or a manual attachment is inserted before a node
- **THEN** that node's cached summary is marked stale and a new summary is generated for that node using the updated prior context

### Requirement: Folder Apple Intelligence summary
The system SHALL generate a folder summary using the per-email summaries of all nodes in the folder and its subfolders, conveying what the threads in that folder are about (including manually attached nodes).

#### Scenario: Folder rollup from node summaries
- **WHEN** a folder summary is requested
- **THEN** the system aggregates the per-email summaries of all nodes contained in the folder and any child folders to produce a concise folder-level summary

### Requirement: Folder summary refresh and debouncing
The system SHALL refresh a folder's summary when any node within that folder (or its subfolders) changes, using a 30-second debounce that cancels and replaces any in-flight Apple Intelligence generation for that folder when a new change arrives.

#### Scenario: Debounced folder refresh
- **WHEN** messages in a folder or its subfolders change and a summary update is requested within 30 seconds
- **THEN** the previous in-flight generation for that folder is cancelled, the timer resets, and the newest generation runs after the debounce delay, replacing any prior result

### Requirement: Folder summary presentation
The system SHALL display the folder summary in the folder header block on the canvas and in the folder inspector as a read-only textbox.

#### Scenario: Folder summary surfaces in UI
- **WHEN** a folder is visible or selected
- **THEN** its summary appears in the folder header block on the canvas and in the folder inspector as a non-editable text field
