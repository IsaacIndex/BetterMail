# ui-visual-style Specification

## Purpose
TBD - created by archiving change add-glassmorphism-ui. Update Purpose after archive.
## Requirements
### Requirement: Glassmorphism Surface Styling
The system SHALL present primary UI surfaces (window background, header, thread canvas nodes, and inspector panel) with a cohesive glassmorphism visual treatment that includes translucency, blur, and subtle highlight/stroke layering, with solid fallbacks when Reduce Transparency is enabled. Liquid Glass treatments for macOS 26+ are temporarily deferred due to technical constraints and should be revisited when feasible.

#### Scenario: App launch surfaces
- **WHEN** the app launches
- **THEN** the main window, header, thread canvas nodes, and inspector panel render with the glassmorphism treatment

#### Scenario: macOS 26 visual consistency
- **WHEN** the app runs on macOS 26 or later with Reduce Transparency disabled
- **THEN** the header and inspector panel render using the same glassmorphism treatment as other primary surfaces

### Requirement: Accessibility-First Legibility
The system SHALL ensure text and iconography remain readable on glass surfaces and SHALL provide a solid fallback when Reduce Transparency is enabled.

#### Scenario: Reduce Transparency enabled
- **WHEN** macOS Reduce Transparency is enabled
- **THEN** glass surfaces use solid backgrounds with sufficient contrast for text

#### Scenario: Standard accessibility settings
- **WHEN** standard accessibility settings are used
- **THEN** text and icons remain legible against translucent surfaces
