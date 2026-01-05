## ADDED Requirements
### Requirement: Glassmorphism Surface Styling
The system SHALL present primary UI surfaces (window background, header, thread list rows, and summary cards) with a cohesive glassmorphism visual treatment that includes translucency, blur, and subtle highlight/stroke layering.

#### Scenario: App launch surfaces
- **WHEN** the app launches
- **THEN** the main window, header, list rows, and summary cards render with the glassmorphism treatment

### Requirement: Accessibility-First Legibility
The system SHALL ensure text and iconography remain readable on glass surfaces and SHALL provide a solid fallback when Reduce Transparency is enabled.

#### Scenario: Reduce Transparency enabled
- **WHEN** macOS Reduce Transparency is enabled
- **THEN** glass surfaces use solid backgrounds with sufficient contrast for text

#### Scenario: Standard accessibility settings
- **WHEN** standard accessibility settings are used
- **THEN** text and icons remain legible against translucent surfaces
