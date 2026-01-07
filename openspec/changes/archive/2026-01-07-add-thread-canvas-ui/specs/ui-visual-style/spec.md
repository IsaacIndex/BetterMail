## MODIFIED Requirements
### Requirement: Glassmorphism Surface Styling
The system SHALL present primary UI surfaces (window background, header, thread canvas nodes, and inspector panel) with a cohesive glassmorphism visual treatment that includes translucency, blur, and subtle highlight/stroke layering. On macOS 26+ the header and inspector SHALL use Liquid Glass treatments, with solid fallbacks when Reduce Transparency is enabled.

#### Scenario: App launch surfaces
- **WHEN** the app launches
- **THEN** the main window, header, thread canvas nodes, and inspector panel render with the glassmorphism treatment

#### Scenario: macOS 26 Liquid Glass
- **WHEN** the app runs on macOS 26 or later with Reduce Transparency disabled
- **THEN** the header and inspector panel render using Liquid Glass effects
