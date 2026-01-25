## ADDED Requirements
### Requirement: TechDocs Folder and Overview
The system SHALL add a `TechDocs/` folder at the repo root containing an architecture overview, module map, data flow and concurrency notes, MailKit helper summary, and pointers to specs/README for newcomers.

#### Scenario: TechDocs created
- **WHEN** the refactor work is delivered
- **THEN** `TechDocs/` exists with clearly named markdown files covering architecture overview, module map, data flow/concurrency, MailKit helper roles, and cross-links back to README/specs

### Requirement: Refactor Migration Log
The system SHALL maintain a migration log inside `TechDocs/` that lists renamed/removed symbols, deprecated components, and any compatibility shims added during the refactor.

#### Scenario: Renames documented
- **WHEN** a function, variable, or component is renamed or removed as part of the refactor
- **THEN** the migration log is updated with the old name, new name/replacement, rationale, and any caller actions required

### Requirement: Documentation Currency Gate
The system SHALL gate refactor completion on updating `TechDocs/` to reflect the final code state so new contributors can rely on it instead of outdated README notes.

#### Scenario: Refactor completion checklist
- **WHEN** the refactor tasks are marked complete
- **THEN** the corresponding TechDocs pages are updated (or explicitly confirmed unchanged) and linked from README/AGENTS so they become the canonical structure reference
