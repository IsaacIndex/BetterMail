## ADDED Requirements

### Requirement: User-Configurable Appearance Mode
The system SHALL provide an app appearance preference in Settings with `System`, `Light`, and `Dark` options, where `System` follows the current macOS appearance setting.

#### Scenario: Default follows macOS appearance
- **WHEN** BetterMail launches with no prior appearance preference saved
- **THEN** the effective app appearance follows the current macOS appearance
- **AND** the Settings control shows `System` as the selected option

#### Scenario: User forces light appearance
- **WHEN** the user selects `Light` in Settings
- **THEN** the app immediately renders using light appearance
- **AND** this override does not require changing macOS system appearance

#### Scenario: User forces dark appearance
- **WHEN** the user selects `Dark` in Settings
- **THEN** the app immediately renders using dark appearance
- **AND** this override does not require changing macOS system appearance

#### Scenario: User returns to system-following mode
- **WHEN** the user switches preference from `Light` or `Dark` back to `System`
- **THEN** BetterMail resumes following macOS appearance changes

### Requirement: Appearance Preference Persistence
The system SHALL persist the user’s selected appearance preference and reapply it on subsequent launches.

#### Scenario: Relaunch retains appearance preference
- **WHEN** a user selects an appearance mode and quits/relaunches BetterMail
- **THEN** BetterMail starts with the previously selected appearance mode active

### Requirement: Appearance Changes Preserve Existing Features
Changing appearance mode SHALL NOT alter existing non-visual behavior in thread canvas and inspector workflows.

#### Scenario: Functional parity across appearance modes
- **WHEN** the user switches between `System`, `Light`, and `Dark` appearance modes
- **THEN** refresh controls, thread selection, folder minimap navigation, and inspector actions continue to behave the same as before the switch
- **AND** no data-fetching, threading, or summary feature is disabled due to appearance mode changes
