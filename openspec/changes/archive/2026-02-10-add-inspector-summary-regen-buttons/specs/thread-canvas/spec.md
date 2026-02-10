## ADDED Requirements

### Requirement: Inspector summary regenerate controls
The inspector SHALL show a "Regenerate" action beside the email summary disclosure and the folder summary field, and SHALL reflect running or unavailable states inline.

#### Scenario: Node summary regen control
- **WHEN** a thread node is selected and its summary appears in the inspector
- **THEN** a "Regenerate" control is shown next to the summary title that triggers summary regeneration, and the control shows a busy/disabled state while regeneration is in progress

#### Scenario: Folder summary regen control
- **WHEN** a folder is selected and its summary appears in the inspector
- **THEN** a "Regenerate" control is shown next to the folder summary label that triggers folder summary regeneration, and the control shows a busy/disabled state when regeneration is running or when Apple Intelligence is unavailable
