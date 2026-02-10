## ADDED Requirements
### Requirement: Floating Date Rail
The system SHALL render a floating date rail pinned to the left edge of the thread canvas that keeps day/month/year labels visible while preserving full-width day band backgrounds.

#### Scenario: Rail pinned to viewport
- **WHEN** the user scrolls horizontally or vertically on the canvas
- **THEN** the date rail remains fixed on the left side of the viewport and its labels stay visible

#### Scenario: Rail aligned to day bands
- **GIVEN** day band backgrounds still span the canvas width
- **WHEN** the user scrolls or the visible day window pages
- **THEN** the date rail’s labels remain vertically aligned with the corresponding day band heights and positions

#### Scenario: Rail respects readability thresholds
- **GIVEN** detailed, compact, and minimal readability states
- **WHEN** the zoom crosses a threshold (day→month→year legend changes)
- **THEN** the date rail switches label granularity to the matching mode without desynchronizing from the canvas content

#### Scenario: Rail in both canvas modes
- **WHEN** the user switches between Default View and Timeline View
- **THEN** the floating date rail remains pinned and aligned with day bands in both modes
