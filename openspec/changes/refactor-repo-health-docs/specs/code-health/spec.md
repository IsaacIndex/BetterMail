## ADDED Requirements
### Requirement: Repository Refactor Audit
The system SHALL produce a repo-wide refactor audit that catalogs functions and variables by module (DataSource, Services, Storage, Threading, ViewModels, UI, Support, Settings, MailHelperExtension), noting proposed renames, access control changes, actor annotations, and dependencies that block refactors.

#### Scenario: Audit produces actionable map
- **WHEN** the refactor starts
- **THEN** there is a written audit that lists each module's functions/variables with proposed new names, desired visibility, actor isolation plans, and any coupling risks to resolve

### Requirement: Naming and Actor Modernization
The system SHALL apply behavior-preserving refactors so functions and variables follow Swift API Design Guidelines, use explicit access control, and declare actor isolation/async boundaries consistently across modules.

#### Scenario: Module refactor applied
- **WHEN** a module (e.g., Storage or ViewModels) is refactored
- **THEN** its functions/variables use guideline-compliant names, explicit `public/internal/private` access where applicable, and actor isolation (`@MainActor` or dedicated actors) is declared for async boundaries with call sites updated accordingly

### Requirement: Deprecated Surface Resolution
The system SHALL remove or formally gate deprecated/unused components (e.g., the deprecated `MessageRowView` and any unused legacy thread list helpers) with clear migration notes and @available annotations when retaining compatibility wrappers.

#### Scenario: Deprecated component addressed
- **WHEN** a deprecated or unused component is discovered during the refactor
- **THEN** it is either removed from build targets or wrapped with an @available deprecation and documented migration/replacement, and the action is recorded in the deprecation log
