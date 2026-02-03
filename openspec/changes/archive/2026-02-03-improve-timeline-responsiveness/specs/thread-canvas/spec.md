## ADDED Requirements
### Requirement: Timeline Interaction Responsiveness
The system SHALL keep Timeline View scrolling and zooming responsive for typical datasets (up to 200 visible timeline entries) by reusing cached layout and text measurements instead of recomputing work on every scroll delta, maintaining smooth visuals within a 16ms frame budget on supported hardware.

#### Scenario: Smooth scroll under typical load
- **WHEN** Timeline View shows up to 200 entries and the user scrolls vertically, horizontally, or diagonally
- **THEN** the interaction remains visually smooth without blank content, and layout is reused rather than rebuilt on each scroll tick

#### Scenario: Smooth zoom transitions
- **WHEN** the user pinches to zoom between readability thresholds
- **THEN** the canvas scales without stalls or dropped frames, using cached measurements where possible

#### Scenario: Cached layout reuse
- **WHEN** the scroll offset changes but zoom, view mode, day window, and node set remain unchanged
- **THEN** the system reuses cached node frames instead of recalculating layout, keeping main-thread work within the 16ms frame budget
