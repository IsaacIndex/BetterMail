## ADDED Requirements
### Requirement: Timeline View Unbounded Entries
The system SHALL render Timeline View entries as a vertical sequence aligned to a timeline rail where each entry uses a left dot + time column followed by inline AI tag chips (when available) and a summary/subject body that may wrap to multiple lines; entry height SHALL expand to fit the summary instead of clipping or overlapping adjacent entries. Timeline entries SHALL omit the sender line and rely on summary/subject plus tags for context, while preserving the existing inspector selection behavior.

#### Scenario: Inline rail layout without clipping
- **WHEN** Timeline View is active
- **THEN** each message renders on a shared rail with a leading dot and time label, and the summary text appears to the right with available width, wrapping to additional lines as needed without horizontal clipping

#### Scenario: No overlap with dynamic heights
- **WHEN** a summary spans multiple lines or tags wrap
- **THEN** the entry's vertical size grows and spacing ensures adjacent entries do not overlap or collide, maintaining readable separation on the rail

#### Scenario: Sender hidden, summary-focused body
- **WHEN** a message is shown in Timeline View
- **THEN** the sender line is not displayed; the body uses the summary text when present, otherwise the subject, and remains selectable to open the inspector as before

#### Scenario: AI tag chips inline with time
- **WHEN** AI-generated tags or folder/title tags exist
- **THEN** they render as pill chips inline after the time label (wrapping to the next line if needed) before the summary body, preserving the `(dot) time  [tags]  summary` visual order
