## ADDED Requirements

### Requirement: Durable Manual Thread Operation History
The system SHALL record manual group, merge, attach, and ungroup mutations as durable write-ahead organization operations whose BetterMail delta commits in one atomic mutation and whose inverse is conditional on current manual-thread fingerprints. The JSON ledger and Core Data stores SHALL use crash-consistent recovery rather than claim cross-store atomicity.

#### Scenario: Manual grouping commits with History
- **WHEN** the user groups or merges selected messages or JWZ threads manually
- **THEN** the prepared operation is durable before the manual group delta commits
- **AND** a failed boundary leaves neither partial grouping nor a falsely completed History row
- **AND** retry uses current fingerprints to avoid applying the same delta twice

#### Scenario: Manual ungrouping commits with History
- **WHEN** the user detaches an eligible manually attached selection
- **THEN** the prepared inverse metadata is durable before the override/group delta commits and rethreading begins

#### Scenario: Conditional undo preserves a later manual change
- **GIVEN** a later edit changed the manual group after an earlier operation completed
- **WHEN** the user requests Undo for the earlier operation
- **THEN** the current manual-thread fingerprint is checked
- **AND** the app presents a conflict/review state rather than silently overwriting the later change
