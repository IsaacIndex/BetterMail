## ADDED Requirements
### Requirement: Open in Mail Filtered Fallback
The system SHALL attempt to open the selected message in Apple Mail by normalized Message-ID first. If that attempt fails, the system SHALL run a single global filtered search using Apple Mail’s AppleScript query pattern `(every message whose subject contains <subject> and sender contains <sender> and date received is within the target day>)` modeled after `OpenInMail (with filter).scpt`, where the date window spans from the start of the message’s calendar day to the start of the next day. When a match is found, the system SHALL open it (or select it in the first message viewer) and activate Mail; when no match is found, it SHALL surface an inline failure state.

#### Scenario: Filtered fallback opens match
- **WHEN** the Message-ID open attempt fails and the filtered fallback runs
- **THEN** the system filters all messages (global scope) by subject substring, sender token substring, and received-date within the target day, opens the first match (or selects it in the viewer), and activates Mail

#### Scenario: Filtered fallback finds no match
- **WHEN** the filtered fallback runs and no message matches the subject, sender token, and day range
- **THEN** the inspector shows an inline failure status while leaving manual copy helpers available for the user to try opening in Mail manually

### Requirement: Open in Mail Copy Helpers Persistent
The system SHALL render copy controls for Message-ID, subject, and mailbox/account alongside the Open in Mail status, and these controls SHALL remain visible regardless of success, searching, or failure states so users can quickly copy targeting metadata.

#### Scenario: Copy helpers always available
- **WHEN** the Open in Mail flow is idle, searching, succeeds, or fails
- **THEN** the inspector still presents copy buttons for the selected message’s Message-ID, subject, and mailbox/account values
