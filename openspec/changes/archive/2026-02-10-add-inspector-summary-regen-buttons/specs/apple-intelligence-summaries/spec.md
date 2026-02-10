## ADDED Requirements

### Requirement: Manual inspector-triggered summary regeneration
The system SHALL let users force Apple Intelligence to regenerate summaries for the selected email node or folder from the inspector, bypassing cached fingerprints and restarting generation immediately.

#### Scenario: Regenerate selected email summary
- **WHEN** the user clicks "Regenerate" in the inspector for the selected email node
- **THEN** the cached summary for that node is invalidated and a new summary generation starts immediately using the latest subject/body/prior-context inputs, showing a running state until completion

#### Scenario: Regenerate selected folder summary
- **WHEN** the user clicks "Regenerate" in the folder inspector
- **THEN** any pending debounced folder generation is cancelled, a new folder summary generation starts immediately using current member summaries, and the cache/status are updated when it finishes
