## ADDED Requirements
### Requirement: Timeline View Entry Presentation
The system SHALL render Timeline View as a single vertical sequence of individual message entries ordered by received time (newest first within the selected range), where each entry shows a time label, sender + subject summary, and one or more tag/title chips. The layout SHALL use the existing inspector selection model so selecting an entry opens the message inspector without leaving Timeline View. When message metadata lacks a concise title or tag, the system SHALL optionally invoke Apple Intelligence to generate a short title or tag set; when Apple Intelligence is unavailable, the entry SHALL fall back to subject-only content without blocking rendering.

#### Scenario: Chronological entries with time labels
- **WHEN** Timeline View is active
- **THEN** each message in the visible date range appears once in a vertical list ordered by received time (newest first) and shows its time label alongside the entry

#### Scenario: Entry content summary and tags
- **WHEN** a message is rendered in Timeline View
- **THEN** its entry shows sender, subject (or summary snippet), and tag/title chips (e.g., folder labels or generated tags) in a compact card style similar to the reference visual

#### Scenario: Selection opens inspector
- **WHEN** the user clicks a timeline entry
- **THEN** that message becomes the current selection and the existing inspector panel opens with its details without exiting Timeline View

#### Scenario: Apple Intelligence-assisted tags optional
- **WHEN** message metadata lacks a concise title or tags
- **THEN** the system may request Apple Intelligence to generate a short title or tag set
- **AND** if Apple Intelligence is unavailable or fails, the entry still renders using available metadata without delay
