# apple-intelligence-summaries Specification

## Purpose
TBD - created by archiving change add-ai-node-folder-summaries. Update Purpose after archive.
## Requirements
### Requirement: Per-email Apple Intelligence summary
The system SHALL generate an Apple Intelligence summary for each email node using (1) the email's subject, (2) the email's body content, and (3) prior emails in the same thread up to that node, including any manually attached nodes that precede it.

#### Scenario: Range-based regeneration
- **WHEN** the user runs "Start Re-GenAI" for a date range in Settings
- **THEN** the system regenerates the per-email summaries for all nodes whose message dates fall within that range in the selected mailbox, even if a valid cache exists

### Requirement: Node summary regeneration on upstream changes
The system SHALL invalidate and regenerate an email node's summary when upstream thread content prior to that node changes (e.g., new earlier messages fetched, or manually attached nodes inserted before it).

#### Scenario: Regenerate after new prior email
- **WHEN** a new earlier email is fetched or a manual attachment is inserted before a node
- **THEN** that node's cached summary is marked stale and a new summary is generated for that node using the updated prior context

### Requirement: Folder Apple Intelligence summary
The system SHALL generate a folder summary using the per-email summaries of all nodes in the folder and its subfolders, conveying what the threads in that folder are about (including manually attached nodes).

#### Scenario: Folder refresh after regeneration
- **WHEN** a batch of per-email summaries is regenerated via "Start Re-GenAI"
- **THEN** folder summaries for folders containing those emails (and their ancestor folders) are refreshed, respecting existing debounce rules

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

### Requirement: Manual inspector-triggered summary regeneration
The system SHALL let users force Apple Intelligence to regenerate summaries for the selected email node or folder from the inspector, bypassing cached fingerprints and restarting generation immediately.

#### Scenario: Regenerate selected email summary
- **WHEN** the user clicks "Regenerate" in the inspector for the selected email node
- **THEN** the cached summary for that node is invalidated and a new summary generation starts immediately using the latest subject/body/prior-context inputs, showing a running state until completion

#### Scenario: Regenerate selected folder summary
- **WHEN** the user clicks "Regenerate" in the folder inspector
- **THEN** any pending debounced folder generation is cancelled, a new folder summary generation starts immediately using current member summaries, and the cache/status are updated when it finishes

